import SwiftUI
import AppKit

/// Which edge stays put when the Quota Meter window resizes.
///
/// The window is a pinned widget the user parks somewhere deliberate, so a
/// reveal/collapse round trip has to leave it exactly where it started. Growth
/// direction is chosen from the screen room available — near the bottom of the
/// display it grows *upward*, pinning its bottom edge — so the matching shrink
/// cannot simply pin the top: it has to release whichever edge that growth
/// pinned. Deciding independently is what made the window walk up the screen by
/// one toolbar height per right-click.
enum HUDLimitsResizeAnchor {
    /// - Parameters:
    ///   - isGrowing: target height exceeds the current height.
    ///   - growsDown: for a growth, whether there is room to expand downward.
    ///   - lastGrowAnchoredTop: what the most recent growth decided; a shrink
    ///     mirrors it instead of re-deciding.
    /// - Returns: true when the top edge stays fixed and the bottom edge moves.
    static func anchorsTop(isGrowing: Bool, growsDown: Bool, lastGrowAnchoredTop: Bool) -> Bool {
        isGrowing ? growsDown : lastGrowAnchoredTop
    }
}

struct AgentCockpitHUDWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let shownSessionCount: Int
    let isCompact: Bool
    let isLimitsOnly: Bool
    let limitsContentHeight: CGFloat
    let limitsContentWidth: CGFloat
    let activeEnabled: Bool
    let compactToolbarVisible: Bool
    let groupByProject: Bool
    let compactPreferredRows: Int
    let compactAutoFitEnabled: Bool

    private var styleInputs: Coordinator.StyleInputs {
        Coordinator.StyleInputs(
            isPinned: isPinned,
            shownSessionCount: shownSessionCount,
            isCompact: isCompact,
            isLimitsOnly: isLimitsOnly,
            limitsContentHeight: limitsContentHeight,
            limitsContentWidth: limitsContentWidth,
            activeEnabled: activeEnabled,
            compactToolbarVisible: compactToolbarVisible,
            groupByProject: groupByProject,
            compactPreferredRows: compactPreferredRows,
            compactAutoFitEnabled: compactAutoFitEnabled
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyleIfNeeded(styleInputs)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)
        context.coordinator.applyStyleIfNeeded(styleInputs)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
#if DEBUG
        private struct DebugAttachmentState {
            var activeConfiguratorCount: Int = 0
            var maxActiveConfiguratorCount: Int = 0
        }
        private static let debugAttachmentLock = NSLock()
        private static var debugAttachmentState = DebugAttachmentState()

        static func debugAttachmentSnapshot() -> (activeConfigurators: Int, maxActiveConfigurators: Int) {
            debugAttachmentLock.lock()
            let state = debugAttachmentState
            debugAttachmentLock.unlock()
            return (
                activeConfigurators: state.activeConfiguratorCount,
                maxActiveConfigurators: state.maxActiveConfiguratorCount
            )
        }

        private static func recordAttach() {
            debugAttachmentLock.lock()
            debugAttachmentState.activeConfiguratorCount += 1
            debugAttachmentState.maxActiveConfiguratorCount = max(
                debugAttachmentState.maxActiveConfiguratorCount,
                debugAttachmentState.activeConfiguratorCount
            )
            debugAttachmentLock.unlock()
        }

        private static func recordDetach() {
            debugAttachmentLock.lock()
            debugAttachmentState.activeConfiguratorCount = max(0, debugAttachmentState.activeConfiguratorCount - 1)
            debugAttachmentLock.unlock()
        }
#endif
        private enum Mode: Hashable {
            case full
            case compact
            case limits
        }

        struct StyleInputs: Equatable {
            let isPinned: Bool
            let shownSessionCount: Int
            let isCompact: Bool
            let isLimitsOnly: Bool
            let limitsContentHeight: CGFloat
            let limitsContentWidth: CGFloat
            let activeEnabled: Bool
            let compactToolbarVisible: Bool
            let groupByProject: Bool
            let compactPreferredRows: Int
            let compactAutoFitEnabled: Bool
        }

        private weak var window: NSWindow?
        private var baselineLevel: NSWindow.Level = .normal
        private var baselineCollectionBehavior: NSWindow.CollectionBehavior = []
        private var baselineHidesOnDeactivate: Bool = false
        private var baselineHasShadow: Bool = true
        private var baselineHasShadowCaptured = false
        private var baselineStyleMask: NSWindow.StyleMask = []
        private var baselineMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        private var baselineMaxSizeCaptured = false
        private var pendingFrameWorkItem: DispatchWorkItem?
        private var isApplyingFrame = false
        private let fallbackStandardStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        private var currentMode: Mode?
        // Keep pinned cockpit above regular windows without covering system tooltip windows.
        private static let pinnedWindowLevel: NSWindow.Level = .statusBar
        private static let pinnedCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        private let fullAutosaveName = "AgentCockpitHUDWindow.full"
        private let compactAutosaveName = "AgentCockpitHUDWindow.compact"
        private let limitsAutosaveName = "AgentCockpitHUDWindow.limits"
        private let rowResizeStep: CGFloat = 31
        private let compactDefaultRowsWhenToolbarVisible: CGFloat = 6
        private let compactDefaultRowsWhenToolbarHidden: CGFloat = 4
        private let compactMinimumRowsWhenToolbarVisible: CGFloat = 1
        private let compactMinimumRowsWhenToolbarHidden: CGFloat = 3
        private let compactMaximumRowsWhenToolbarVisible: CGFloat = 10
        private let compactMinimumWidth: CGFloat = 330
        private let compactDefaultFrameWidth: CGFloat = 330
        private let limitsMinimumWidth: CGFloat = 220
        private let limitsDefaultFrameWidth: CGFloat = 380
        private let limitsRowHeight: CGFloat = 30
        private let limitsMaximumRows: CGFloat = 9
        private let compactHeaderHeight: CGFloat = 44.5
        private let compactDisabledCalloutHeight: CGFloat = 56
        private let fullDefaultFrameSize = NSSize(width: 644, height: 320)
        private var cachedFrameByMode: [Mode: NSRect] = [:]
        /// Which edge the last Quota Meter *growth* pinned, so the matching
        /// shrink can release the same one. See `HUDLimitsResizeAnchor`.
        private var lastLimitsGrowAnchoredTop: Bool = true
        private var lastAppliedCompactToolbarVisibility: Bool?
        private var lastAppliedCompactPreferredRows: Int?
        private var lastAppliedCompactAutoFitEnabled: Bool?
        private var lastAppliedStyleInputs: StyleInputs?

        func attach(to newWindow: NSWindow) {
            guard window !== newWindow else { return }
            if window != nil {
#if DEBUG
                Self.recordDetach()
#endif
            }
            window = newWindow
#if DEBUG
            Self.recordAttach()
#endif
            lastAppliedStyleInputs = nil
            captureBaselineWindowStateIfSafe(from: newWindow)
            captureBaselineStyleMaskIfNeeded(from: newWindow.styleMask)
        }

        deinit {
            pendingFrameWorkItem?.cancel()
            if window != nil {
#if DEBUG
                Self.recordDetach()
#endif
            }
        }

        func applyStyleIfNeeded(_ inputs: StyleInputs) {
            guard lastAppliedStyleInputs != inputs else { return }
            applyStyle(
                isPinned: inputs.isPinned,
                shownSessionCount: inputs.shownSessionCount,
                isCompact: inputs.isCompact,
                isLimitsOnly: inputs.isLimitsOnly,
                limitsContentHeight: inputs.limitsContentHeight,
                limitsContentWidth: inputs.limitsContentWidth,
                activeEnabled: inputs.activeEnabled,
                compactToolbarVisible: inputs.compactToolbarVisible,
                groupByProject: inputs.groupByProject,
                compactPreferredRows: inputs.compactPreferredRows,
                compactAutoFitEnabled: inputs.compactAutoFitEnabled
            )
            lastAppliedStyleInputs = inputs
        }

        func applyStyle(isPinned: Bool,
                        shownSessionCount: Int,
                        isCompact: Bool,
                        isLimitsOnly: Bool,
                        limitsContentHeight: CGFloat,
                        limitsContentWidth: CGFloat,
                        activeEnabled: Bool,
                        compactToolbarVisible: Bool,
                        groupByProject: Bool,
                        compactPreferredRows: Int,
                        compactAutoFitEnabled: Bool) {
            guard let window else { return }
            captureBaselineWindowStateIfSafe(from: window)
            if let currentMode {
                cachedFrameByMode[currentMode] = window.frame
            }
            let clampedCompactPreferredRows = clampedPreferredCompactRows(compactPreferredRows)
            // Compact always reserves toolbar height, auto-fit or not. Auto-fit
            // means "height follows session count" — it must not also mean
            // "height follows toolbar visibility", or revealing the toolbar on
            // hover resizes the window under the pointer. The Quota Meter keeps
            // its own rule: its chrome mode decides whether the toolbar is part
            // of the window at all.
            let includesToolbarForStableSizing = isLimitsOnly ? compactToolbarVisible : true

            if window.identifier?.rawValue != "AgentCockpit" {
                window.identifier = NSUserInterfaceItemIdentifier("AgentCockpit")
            }

            window.isMovableByWindowBackground = true
            window.isRestorable = true
            // Keep vertical resize snapping aligned to row increments so partial rows
            // are not clipped at the window edge.
            window.resizeIncrements = isLimitsOnly
                ? NSSize(width: 1, height: 1)
                : NSSize(width: 1, height: rowResizeStep)
            window.contentResizeIncrements = isLimitsOnly
                ? NSSize(width: 1, height: 1)
                : NSSize(width: 1, height: rowResizeStep)

            if isCompact {
                let wasAlreadyCompact = currentMode == .compact
                let previousCompactToolbarVisibility = lastAppliedCompactToolbarVisibility
                applyCompactChrome(to: window)
                if isLimitsOnly {
                    let targetHeight = limitsWindowHeight(
                        for: window,
                        contentHeight: limitsContentHeight,
                        includesDisabledCallout: !activeEnabled,
                        includesToolbar: includesToolbarForStableSizing
                    )
                    // Hug the content width: fix the window to the compact limits row's
                    // natural width so it never tucks wider than its content (no dead
                    // space on the right). Resizes once when the Enlarged font toggles.
                    let limitsWidth = max(limitsMinimumWidth, limitsContentWidth)
                    window.minSize = NSSize(
                        width: limitsWidth,
                        height: targetHeight
                    )
                    window.maxSize = NSSize(width: limitsWidth, height: targetHeight)
                } else {
                    window.maxSize = baselineMaxSize
                    window.minSize = NSSize(
                        width: compactMinimumWidth,
                        height: compactMinimumWindowHeight(
                            for: window,
                            includesDisabledCallout: !activeEnabled,
                            includesToolbar: includesToolbarForStableSizing
                        )
                    )
                }
                applyModeTransition(
                    to: isLimitsOnly ? .limits : .compact,
                    window: window,
                    activeEnabled: activeEnabled,
                    compactToolbarVisible: includesToolbarForStableSizing,
                    compactPreferredRows: clampedCompactPreferredRows,
                    limitsContentHeight: limitsContentHeight
                )
                if isLimitsOnly {
                    applyLimitsDefaultSize(
                        to: window,
                        contentHeight: limitsContentHeight,
                        activeEnabled: activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        appliesDefaultWidth: false,
                        animated: previousCompactToolbarVisibility != compactToolbarVisible
                    )
                }
                // No toolbar-visibility resize for ordinary Compact: its height
                // is reserved for the toolbar whether or not it is on screen, so
                // revealing it has nothing to resize.
                if !isLimitsOnly,
                   compactAutoFitEnabled,
                   !groupByProject {
                    applyCompactVisibleRowsAutoHeight(
                        shownSessionCount: shownSessionCount,
                        activeEnabled: activeEnabled,
                        window: window
                    )
                } else if !isLimitsOnly,
                          shouldApplyCompactBaselineHeight(
                    compactPreferredRows: clampedCompactPreferredRows,
                    compactAutoFitEnabled: compactAutoFitEnabled
                ), wasAlreadyCompact {
                    applyCompactBaselineHeight(
                        compactPreferredRows: clampedCompactPreferredRows,
                        activeEnabled: activeEnabled,
                        includesToolbar: includesToolbarForStableSizing,
                        window: window
                    )
                }
                lastAppliedCompactToolbarVisibility = compactToolbarVisible
                lastAppliedCompactPreferredRows = clampedCompactPreferredRows
                lastAppliedCompactAutoFitEnabled = compactAutoFitEnabled
                window.title = ""
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            } else {
                captureBaselineStyleMaskIfNeeded(from: window.styleMask)
                restoreStandardChrome(to: window)
                window.minSize = NSSize(width: 560, height: 320)
                window.maxSize = baselineMaxSize
                applyModeTransition(
                    to: .full,
                    window: window,
                    activeEnabled: activeEnabled,
                    compactToolbarVisible: true,
                    compactPreferredRows: clampedCompactPreferredRows,
                    limitsContentHeight: limitsContentHeight
                )
                lastAppliedCompactToolbarVisibility = nil
                lastAppliedCompactPreferredRows = nil
                lastAppliedCompactAutoFitEnabled = nil
                window.title = "Agent Cockpit (\(shownSessionCount))"
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
            }

            if isPinned {
                window.level = Self.pinnedWindowLevel
                window.collectionBehavior = baselineCollectionBehavior.union(Self.pinnedCollectionBehavior)
                window.hidesOnDeactivate = false
            } else {
                // Restore non-pinned behavior to the window's baseline values.
                window.level = Self.sanitizedUnpinnedLevel(from: baselineLevel)
                window.collectionBehavior = Self.sanitizedUnpinnedCollectionBehavior(from: baselineCollectionBehavior)
                window.hidesOnDeactivate = baselineHidesOnDeactivate
            }
        }

        static func sanitizedUnpinnedLevel(from baselineLevel: NSWindow.Level) -> NSWindow.Level {
            if baselineLevel == .screenSaver || baselineLevel == pinnedWindowLevel {
                return .normal
            }
            return baselineLevel
        }

        static func sanitizedUnpinnedCollectionBehavior(from baselineCollectionBehavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
            baselineCollectionBehavior.subtracting(pinnedCollectionBehavior)
        }

        private func captureBaselineWindowStateIfSafe(from window: NSWindow) {
            // If the window is currently pinned, preserve the previous baseline so unpin restores
            // regular behavior instead of re-capturing pinned state as the baseline.
            guard window.level != .screenSaver,
                  window.level != Self.pinnedWindowLevel else { return }
            baselineLevel = window.level
            baselineCollectionBehavior = Self.sanitizedUnpinnedCollectionBehavior(from: window.collectionBehavior)
            baselineHidesOnDeactivate = window.hidesOnDeactivate
            if !baselineHasShadowCaptured {
                baselineHasShadow = window.hasShadow
                baselineHasShadowCaptured = true
            }
            if !baselineMaxSizeCaptured {
                baselineMaxSize = window.maxSize
                baselineMaxSizeCaptured = true
            }
        }

        private func applyCompactChrome(to window: NSWindow) {
            var compactMask = window.styleMask
            compactMask.remove(.titled)
            compactMask.insert(.fullSizeContentView)
            window.styleMask = compactMask
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Make the window transparent so the SwiftUI clipShape's rounded corners
            // are the only visible boundary — eliminates the double-corner artifact
            // caused by the NSWindow frame's own corner radius overlapping the view clip.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            applyClearHostingBackground(to: window)
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in buttons {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                button.isHidden = true
                button.isEnabled = false
            }
            if let container = window.standardWindowButton(.closeButton)?.superview {
                container.isHidden = true
            }
        }

        private func restoreStandardChrome(to window: NSWindow) {
            var restoredMask = baselineStyleMask
            if !restoredMask.contains(.titled) {
                restoredMask.formUnion(fallbackStandardStyleMask)
                restoredMask.remove(.fullSizeContentView)
            }
            window.styleMask = restoredMask
            window.titlebarSeparatorStyle = .automatic
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = baselineHasShadow
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in buttons {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                button.isHidden = false
                button.isEnabled = true
            }
            if let container = window.standardWindowButton(.closeButton)?.superview {
                container.isHidden = false
            }
        }

        private func applyClearHostingBackground(to window: NSWindow) {
            for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        private func captureBaselineStyleMaskIfNeeded(from styleMask: NSWindow.StyleMask) {
            guard styleMask.contains(.titled) else {
                if baselineStyleMask.isEmpty {
                    baselineStyleMask = fallbackStandardStyleMask
                }
                return
            }
            baselineStyleMask = styleMask
        }

        private func applyModeTransition(to mode: Mode,
                                         window: NSWindow,
                                         activeEnabled: Bool,
                                         compactToolbarVisible: Bool,
                                         compactPreferredRows: Int,
                                         limitsContentHeight: CGFloat) {
            guard currentMode != mode else { return }

            let previousMode = currentMode
                ?? inferredMode(from: window.frameAutosaveName)
            if let previousMode {
                persistFrame(window.frame, for: previousMode, window: window)
            }

            let targetAutosaveName = autosaveName(for: mode)
            if window.frameAutosaveName != targetAutosaveName {
                window.setFrameAutosaveName(targetAutosaveName)
            }

            let restoredFromCache: Bool = {
                guard let cached = cachedFrameByMode[mode] else { return false }
                setWindowFrame(cached, display: true, animate: false)
                return true
            }()
            let restored = restoredFromCache || window.setFrameUsingName(targetAutosaveName)
            if !restored {
                switch mode {
                case .limits:
                    self.applyLimitsDefaultSize(
                        to: window,
                        contentHeight: limitsContentHeight,
                        activeEnabled: activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        appliesDefaultWidth: true,
                        animated: false
                    )
                case .compact:
                    applyCompactDefaultSize(
                        to: window,
                        includesDisabledCallout: !activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        compactPreferredRows: compactPreferredRows
                    )
                case .full:
                    applyFullDefaultSize(to: window)
                }
            }

            currentMode = mode
            cachedFrameByMode[mode] = window.frame
        }

        private func autosaveName(for mode: Mode) -> String {
            switch mode {
            case .full:
                return fullAutosaveName
            case .compact:
                return compactAutosaveName
            case .limits:
                return limitsAutosaveName
            }
        }

        private func inferredMode(from autosaveName: String) -> Mode? {
            if autosaveName == fullAutosaveName { return .full }
            if autosaveName == compactAutosaveName { return .compact }
            if autosaveName == limitsAutosaveName { return .limits }
            return nil
        }

        private func persistFrame(_ frame: NSRect, for mode: Mode, window: NSWindow) {
            cachedFrameByMode[mode] = frame
            window.saveFrame(usingName: autosaveName(for: mode))
        }

        private func compactMinimumWindowHeight(for window: NSWindow,
                                                includesDisabledCallout: Bool,
                                                includesToolbar: Bool) -> CGFloat {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            let minimumRows = includesToolbar
                ? compactMinimumRowsWhenToolbarVisible
                : compactMinimumRowsWhenToolbarHidden
            return compactContentHeight(forRows: minimumRows, includesToolbar: includesToolbar) + calloutHeight + chromeHeight
        }

        private func compactContentHeight(forRows rows: CGFloat, includesToolbar: Bool) -> CGFloat {
            (includesToolbar ? compactHeaderHeight : 0) + (rows * rowResizeStep)
        }

        private func limitsWindowHeight(for window: NSWindow,
                                        contentHeight: CGFloat,
                                        includesDisabledCallout: Bool,
                                        includesToolbar: Bool) -> CGFloat {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            let clampedContentHeight = max(limitsRowHeight, min(contentHeight, limitsRowHeight * limitsMaximumRows))
            return (includesToolbar ? compactHeaderHeight + 0.5 : 0)
                + clampedContentHeight
                + calloutHeight
                + chromeHeight
        }

        private func applyCompactDefaultSize(to window: NSWindow,
                                             includesDisabledCallout: Bool,
                                             includesToolbar: Bool,
                                             compactPreferredRows: Int) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            let defaultRows = includesToolbar
                ? CGFloat(compactPreferredRows)
                : compactDefaultRowsWhenToolbarHidden
            let targetHeight = max(
                window.minSize.height,
                compactContentHeight(forRows: defaultRows, includesToolbar: includesToolbar) + calloutHeight + chromeHeight
            )
            let targetWidth = max(window.minSize.width, compactDefaultFrameWidth)

            var frame = window.frame
            let widthChanged = abs(frame.width - targetWidth) > 1
            let previousHeight = frame.height
            if widthChanged {
                frame.size.width = targetWidth
            }
            if abs(previousHeight - targetHeight) <= 1 {
                guard widthChanged else { return }
                setWindowFrame(frame, display: true, animate: false)
                return
            }
            frame.origin.y += previousHeight - targetHeight
            frame.size.height = targetHeight
            setWindowFrame(frame, display: true, animate: false)
        }

        private func clampedPreferredCompactRows(_ rows: Int) -> Int {
            max(Int(compactMinimumRowsWhenToolbarHidden), min(rows, Int(compactMaximumRowsWhenToolbarVisible)))
        }

        private func shouldApplyCompactBaselineHeight(compactPreferredRows: Int,
                                                      compactAutoFitEnabled: Bool) -> Bool {
            if lastAppliedCompactPreferredRows != compactPreferredRows {
                return true
            }
            if lastAppliedCompactAutoFitEnabled == true, !compactAutoFitEnabled {
                return true
            }
            return false
        }

        private func applyCompactBaselineHeight(compactPreferredRows: Int,
                                                activeEnabled: Bool,
                                                includesToolbar: Bool,
                                                window: NSWindow) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = activeEnabled ? 0 : compactDisabledCalloutHeight
            let targetHeight = max(
                window.minSize.height,
                compactContentHeight(
                    forRows: CGFloat(compactPreferredRows),
                    includesToolbar: includesToolbar
                ) + calloutHeight + chromeHeight
            )
            guard abs(window.frame.height - targetHeight) > 0.5 else { return }

            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            setWindowFrame(frame, display: true, animate: false)
        }

        private func applyCompactToolbarVisibilityTransition(to isVisible: Bool,
                                                             groupByProject: Bool,
                                                             window: NSWindow) {
            let rowDelta = groupByProject
                ? 0
                : (compactDefaultRowsWhenToolbarVisible - compactDefaultRowsWhenToolbarHidden)
            let delta = compactHeaderHeight + (rowDelta * rowResizeStep)
            guard delta > 0 else { return }

            var frame = window.frame
            let proposedHeight = isVisible ? frame.height + delta : frame.height - delta
            let targetHeight = max(window.minSize.height, proposedHeight)
            guard abs(targetHeight - frame.height) > 0.5 else { return }

            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            // This path only runs when the toolbar visibility toggles, so the
            // window resize animates with the toolbar reveal/hide.
            setWindowFrame(frame, display: true, animate: true)
        }

        private func applyCompactVisibleRowsAutoHeight(shownSessionCount: Int,
                                                       activeEnabled: Bool,
                                                       window: NSWindow) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = activeEnabled ? 0 : compactDisabledCalloutHeight
            let clampedRows = max(
                Int(compactMinimumRowsWhenToolbarVisible),
                min(shownSessionCount, Int(compactMaximumRowsWhenToolbarVisible))
            )
            let targetHeight = max(
                window.minSize.height,
                compactContentHeight(forRows: CGFloat(clampedRows), includesToolbar: true) + calloutHeight + chromeHeight
            )

            guard abs(window.frame.height - targetHeight) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            setWindowFrame(frame, display: true, animate: false)
        }

        private func applyFullDefaultSize(to window: NSWindow) {
            var frame = window.frame
            let targetWidth = max(window.minSize.width, fullDefaultFrameSize.width)
            let targetHeight = max(window.minSize.height, fullDefaultFrameSize.height)
            let oldHeight = frame.height

            guard abs(frame.width - targetWidth) > 1 || abs(frame.height - targetHeight) > 1 else {
                return
            }

            frame.size.width = targetWidth
            frame.size.height = targetHeight
            // Preserve top edge when applying first-run defaults.
            frame.origin.y += oldHeight - targetHeight
            setWindowFrame(frame, display: true, animate: false)
        }

        private func applyLimitsDefaultSize(to window: NSWindow,
                                            contentHeight: CGFloat,
                                            activeEnabled: Bool,
                                            includesToolbar: Bool,
                                            appliesDefaultWidth: Bool,
                                            animated: Bool) {
            // Clamp to maxSize.width so the window snaps to the hugged content width
            // even when its saved/previous frame was wider than the content.
            let unclampedWidth = appliesDefaultWidth
                ? max(window.minSize.width, limitsDefaultFrameWidth)
                : max(window.minSize.width, window.frame.width)
            let targetWidth = min(window.maxSize.width, unclampedWidth)
            let targetHeight = max(
                window.minSize.height,
                self.limitsWindowHeight(
                    for: window,
                    contentHeight: contentHeight,
                    includesDisabledCallout: !activeEnabled,
                    includesToolbar: includesToolbar
                )
            )

            var frame = window.frame
            let oldHeight = frame.height
            guard abs(frame.width - targetWidth) > 1 || abs(frame.height - targetHeight) > 1 else {
                return
            }

            frame.size.width = targetWidth
            frame.size.height = targetHeight

            // Reveal and collapse must pin the same edge, or the window walks.
            // Growth picks its direction from available screen room; the shrink
            // mirrors that choice rather than deciding for itself.
            let isGrowing = targetHeight > oldHeight
            let growsDown = isGrowing
                ? shouldGrowLimitsWindowDown(window: window, targetHeight: targetHeight)
                : false
            let anchorsTop = HUDLimitsResizeAnchor.anchorsTop(
                isGrowing: isGrowing,
                growsDown: growsDown,
                lastGrowAnchoredTop: lastLimitsGrowAnchoredTop
            )
            if isGrowing {
                lastLimitsGrowAnchoredTop = anchorsTop
            }
            if anchorsTop {
                frame.origin.y += oldHeight - targetHeight
            }
            // Animate only when the toolbar is toggling, so the window resize
            // moves with the toolbar reveal/hide instead of snapping. Other
            // limits resizes (content height changes) stay instant.
            setWindowFrame(frame, display: true, animate: animated)
        }

        /// Whether the window grows downward (top edge pinned) given the room
        /// available on screen. Only meaningful while growing — the caller must
        /// not consult it on a shrink, where its `guard` would answer `true`
        /// unconditionally and pin the top regardless of which edge the matching
        /// growth actually pinned.
        private func shouldGrowLimitsWindowDown(window: NSWindow, targetHeight: CGFloat) -> Bool {
            guard targetHeight > window.frame.height,
                  let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return true
            }
            let frame = window.frame
            let extraHeight = targetHeight - frame.height
            let roomBelow = max(0, frame.minY - visibleFrame.minY)
            let roomAbove = max(0, visibleFrame.maxY - frame.maxY)
            if roomBelow >= extraHeight { return true }
            if roomAbove >= extraHeight { return false }
            return roomBelow >= roomAbove
        }

        private func setWindowFrame(_ frame: NSRect, display: Bool, animate: Bool) {
            guard let window else { return }
            let current = window.frame
            guard abs(current.origin.x - frame.origin.x) > 1 ||
                    abs(current.origin.y - frame.origin.y) > 1 ||
                    abs(current.width - frame.width) > 1 ||
                    abs(current.height - frame.height) > 1 else {
                return
            }

            pendingFrameWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, !self.isApplyingFrame else { return }
                let current = window.frame
                guard abs(current.origin.x - frame.origin.x) > 1 ||
                        abs(current.origin.y - frame.origin.y) > 1 ||
                        abs(current.width - frame.width) > 1 ||
                        abs(current.height - frame.height) > 1 else {
                    return
                }
                self.isApplyingFrame = true
                window.setFrame(frame, display: display, animate: animate)
                self.isApplyingFrame = false
            }
            pendingFrameWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }
}
