import SwiftUI
import AppKit

/// Finds the nearest NSSplitView ancestor and sets an autosave name
/// so divider position persists across relaunches.
struct SplitViewAutosave: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let v = SplitFinderView(key: key)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SplitFinderView: NSView {
    private let key: String
    private var didRegisterResizeObserve = false
    private var isApplying = false
    private var lastAxisLength: CGFloat = 0
    private var isUserDraggingDivider = false
    private var eventMonitor: Any?
    init(key: String) { self.key = key; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Apply immediately so the divider position is restored before first paint
        apply()
        // Also apply on the next runloop in case the split view is created slightly later
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Cover cases where the split view is already in the hierarchy but not yet in a window
        apply()
    }

    private func apply() {
        guard let split = findSplitView(from: self) else { return }
        if split.autosaveName != key {
            split.autosaveName = key
        }

        // Apply saved absolute primary-pixel size if present; otherwise, apply a stable initial
        // default without overriding an existing AppKit autosave.
        if !applySavedPositionIfAvailable(split) {
            applyInitialPositionIfNeeded(split)
            seedSavedPositionFromCurrent(split)
            // If initial couldn't apply yet (zero size), retry shortly to ensure it lands before first visible content swap.
            scheduleInitialRetriesIfNeeded(split)
        } else {
            // If we had a saved pixel preference, mark initialized so defaults won't run later
            UserDefaults.standard.set(true, forKey: "SplitInit." + key)
        }


        // One-time: observe resize to re-apply initial position if we missed the first valid size.
        if !didRegisterResizeObserve {
            didRegisterResizeObserve = true
            NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self, weak split] _ in
                guard let self, let split else { return }
                self.handleSplitResized(split)
            }
            // Re-assert position after common post-launch transitions (e.g., loading animation → transcript)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak split] in
                guard let self, let split else { return }
                _ = self.applySavedPositionIfAvailable(split)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak split] in
                guard let self, let split else { return }
                _ = self.applySavedPositionIfAvailable(split)
            }

            // Install local mouse monitor to detect actual divider drags and persist exactly on mouse up
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self, weak split] event in
                guard let self, let split else { return event }
                switch event.type {
                case .leftMouseDown:
                    if self.hitDivider(split: split, event: event) { self.isUserDraggingDivider = true }
                case .leftMouseDragged:
                    // no-op; we persist on mouse up
                    break
                case .leftMouseUp:
                    if self.isUserDraggingDivider {
                        self.isUserDraggingDivider = false
                        // Persist current position after drag completes
                        let axisLen = self.primaryAxisLength(split)
                        let isHSplit = self.key.hasSuffix("-H") || split.isVertical
                        let clamped = self.clamp(self.primaryPosition(split), toAxisLength: axisLen, isHSplit: isHSplit)
                        UserDefaults.standard.set(Double(clamped), forKey: self.savedPrimaryKey())
                        self.lastAxisLength = axisLen
                    }
                default:
                    break
                }
                return event
            }
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }

    private func findSplitView(from start: NSView?) -> NSSplitView? {
        // Ascend through ancestors first (fast path)
        var v = start?.superview
        while let cur = v {
            if let s = cur as? NSSplitView { return s }
            v = cur.superview
        }
        // Fallback: search the window's content view subtree (SwiftUI may wrap background as a sibling)
        if let root = self.window?.contentView {
            return findSplitViewRecursively(in: root)
        }
        return nil
    }

    private func findSplitViewRecursively(in view: NSView) -> NSSplitView? {
        if let s = view as? NSSplitView { return s }
        for child in view.subviews {
            if let found = findSplitViewRecursively(in: child) { return found }
        }
        return nil
    }

    private func applyInitialPositionIfNeeded(_ split: NSSplitView) {
        let defaults = UserDefaults.standard
        let initKey = "SplitInit." + key
        if defaults.bool(forKey: initKey) { return }
        // If AppKit has an existing autosaved frame for this split key, respect it and mark initialized.
        let appKitAutosaveKey = "NSSplitView Subview Frames " + key
        if defaults.object(forKey: appKitAutosaveKey) != nil {
            defaults.set(true, forKey: initKey)
            return
        }

        // Ensure we have a meaningful size to compute from
        split.layoutSubtreeIfNeeded()
        let isHSplit = split.isVertical // HSplitView → side-by-side panes
        let axisLength: CGFloat = isHSplit ? split.bounds.width : split.bounds.height
        guard axisLength > 10 else { return }

        // Defaults: vertical layout (HSplitView) = 60/40 list/transcript; horizontal (VSplitView) = 50/50 top/bottom
        let desiredRatio: CGFloat = isHSplit ? 0.60 : 0.50
        var primaryPoints = axisLength * desiredRatio

        // Clamp to known HIG-aligned mins used by our panes
        if isHSplit {
            // Left list >= 320, right transcript >= 450
            let minPrimary: CGFloat = 320
            let minSecondary: CGFloat = 450
            primaryPoints = max(minPrimary, min(primaryPoints, axisLength - minSecondary))
        } else {
            // Top list >= 180, bottom transcript >= 240
            let minPrimary: CGFloat = 180
            let minSecondary: CGFloat = 240
            primaryPoints = max(minPrimary, min(primaryPoints, axisLength - minSecondary))
        }

        isApplying = true
        split.setPosition(primaryPoints, ofDividerAt: 0)
        isApplying = false

        // Mark initialized so we don't override user-saved autosave on next launches
        defaults.set(true, forKey: initKey)
    }

    private func scheduleInitialRetriesIfNeeded(_ split: NSSplitView) {
        let defaults = UserDefaults.standard
        let initKey = "SplitInit." + key
        if defaults.bool(forKey: initKey) { return }
        // Try a few short retries to catch the first non-zero layout
        let delays: [TimeInterval] = [0.05, 0.12, 0.25, 0.5]
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self, weak split] in
                guard let self, let split else { return }
                self.applyInitialPositionIfNeeded(split)
                if defaults.bool(forKey: initKey) {
                    self.seedSavedPositionFromCurrent(split)
                }
            }
        }
    }

    private func savedPrimaryKey() -> String { "SplitPrimaryPixels." + key }

    private func primaryAxisLength(_ split: NSSplitView) -> CGFloat {
        let isHSplit = split.isVertical
        return isHSplit ? split.bounds.width : split.bounds.height
    }

    private func primaryPosition(_ split: NSSplitView) -> CGFloat {
        guard split.subviews.indices.contains(0) else { return 0 }
        let primary = split.subviews[0]
        let isHSplit = key.hasSuffix("-H") || split.isVertical
        return isHSplit ? primary.frame.width : primary.frame.height
    }

    private func clamp(_ position: CGFloat, toAxisLength axisLength: CGFloat, isHSplit: Bool) -> CGFloat {
        if isHSplit {
            let minPrimary: CGFloat = 320
            let minSecondary: CGFloat = 450
            return max(minPrimary, min(position, axisLength - minSecondary))
        } else {
            let minPrimary: CGFloat = 180
            let minSecondary: CGFloat = 240
            return max(minPrimary, min(position, axisLength - minSecondary))
        }
    }

    private func seedSavedPositionFromCurrent(_ split: NSSplitView) {
        let defaults = UserDefaults.standard
        let key = savedPrimaryKey()
        if defaults.object(forKey: key) == nil {
            let pos = primaryPosition(split)
            defaults.set(Double(pos), forKey: key)
        }
    }

    private func applySavedPositionIfAvailable(_ split: NSSplitView) -> Bool {
        let defaults = UserDefaults.standard
        let key = savedPrimaryKey()
        guard let savedAny = defaults.object(forKey: key) else { return false }
        let saved = CGFloat((savedAny as? NSNumber)?.doubleValue ?? 0)
        let isHSplit = split.isVertical
        let axisLen = primaryAxisLength(split)
        guard axisLen > 10 else { return false }
        var target = clamp(saved, toAxisLength: axisLen, isHSplit: isHSplit)
        // Avoid redundant set when already close
        let current = primaryPosition(split)
        if abs(current - target) < 0.5 { return true }
        isApplying = true
        split.setPosition(target, ofDividerAt: 0)
        isApplying = false
        lastAxisLength = axisLen
        return true
    }

    private func handleSplitResized(_ split: NSSplitView) {
        if isApplying { return }
        // Ensure initial default lands as soon as layout becomes meaningful
        let defaults = UserDefaults.standard
        let initKey = "SplitInit." + key
        if !defaults.bool(forKey: initKey) {
            // If we already have a saved pixel size, prefer it and mark initialized
            if hasSavedPosition() {
                _ = applySavedPositionIfAvailable(split)
                defaults.set(true, forKey: initKey)
            } else {
                applyInitialPositionIfNeeded(split)
                if defaults.bool(forKey: initKey) {
                    seedSavedPositionFromCurrent(split)
                }
            }
        }
        let axisLen = primaryAxisLength(split)
        let current = primaryPosition(split)
        let savedKey = savedPrimaryKey()
        let savedVal = CGFloat((defaults.object(forKey: savedKey) as? NSNumber)?.doubleValue ?? 0)
        let isHSplit = split.isVertical

        // If the user is actively dragging, persist and don't re-apply
        if isUserDraggingDivider {
            let clamped = clamp(current, toAxisLength: axisLen, isHSplit: isHSplit)
            defaults.set(Double(clamped), forKey: savedKey)
            lastAxisLength = axisLen
            return
        }

        // If the axis length hasn't changed, treat the resize as a divider drag and persist current position.
        // This avoids relying on event monitors that can miss edge cases and ensures both up/down drags persist.
        let axisDelta = abs(axisLen - lastAxisLength)
        if axisDelta <= 0.5 {
            let clamped = clamp(current, toAxisLength: axisLen, isHSplit: isHSplit)
            defaults.set(Double(clamped), forKey: savedKey)
            lastAxisLength = axisLen
            return
        }

        // On container-driven resize: re-apply saved absolute position, if any.
        if savedVal > 0 {
            let clamped = clamp(savedVal, toAxisLength: axisLen, isHSplit: isHSplit)
            // Only re-apply if drifted meaningfully or the axis length changed
            if abs(current - clamped) > 0.5 || abs(axisLen - lastAxisLength) > 0.5 {
                isApplying = true
                split.setPosition(clamped, ofDividerAt: 0)
                isApplying = false
            }
        }
        lastAxisLength = axisLen
    }

    private func hasSavedPosition() -> Bool {
        UserDefaults.standard.object(forKey: savedPrimaryKey()) != nil
    }

    private func hitDivider(split: NSSplitView, event: NSEvent) -> Bool {
        let pt = split.convert(event.locationInWindow, from: nil)
        let isHSplit = split.isVertical
        let thickness = split.dividerThickness
        let fuzz: CGFloat = max(6, thickness + 4)
        guard split.subviews.count >= 2 else { return false }
        let first = split.subviews[0]
        let second = split.subviews[1]
        // Compute divider position from subview edges to avoid assumptions about origins
        let dividerPos: CGFloat = isHSplit ? first.frame.maxX : min(first.frame.maxY, second.frame.minY)
        let rect: NSRect
        if isHSplit {
            rect = NSRect(x: dividerPos - fuzz/2, y: 0, width: fuzz, height: split.bounds.height)
        } else {
            rect = NSRect(x: 0, y: dividerPos - fuzz/2, width: split.bounds.width, height: fuzz)
        }
        return rect.contains(pt)
    }
}
