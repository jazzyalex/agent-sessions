import Combine
import AppKit
import SwiftUI

/// Non-activating panel that never becomes key or main.
private final class QuotaStripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu bar strip: one borderless non-activating panel on the target screen. The
/// SwiftUI notch shape grows from the collapsed wings into the real Quota Meter. Clicks
/// outside the shape pass through (`hitTest` limited to the shape, `ignoresMouseEvents`
/// toggled from mouse monitors, which also drive hover).
@MainActor
final class QuotaStripController {
    static let windowIdentifier = "QuotaStrip"
    private static let openDelay: TimeInterval = 0.3
    private static let closeDelay: TimeInterval = 0.1
    private static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    private static let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0)

    /// Builds the strip's click menu (the old menu bar item's menu).
    var menuProvider: (() -> NSMenu?)?
    private(set) var isPresented = false
    private(set) var screenID: UInt32?

    private let codexIndexer: SessionIndexer
    private let claudeIndexer: ClaudeSessionIndexer
    private let opencodeIndexer: OpenCodeSessionIndexer
    private let activeCodex: CodexActiveSessionsModel
    private let codexUsage: CodexUsageModel
    private let claudeUsage: ClaudeUsageModel

    private var panel: QuotaStripPanel?
    private var host: QuotaStripHostingView<AnyView>?
    private var model: QuotaStripModel?
    /// Geometry of the screen the strip is on now; updated on every rebuild and reposition.
    private var currentLayout: QuotaStripLayout?
    private var sizeObservation: AnyCancellableBox?
    private var styleObservation: AnyCancellableBox?
    private var popoverObservation: AnyCancellableBox?
    private var mouseMonitors: [Any] = []
    private var pointerInside = false
    private var hoverTimer: Timer?
    /// This controller's registration in `QuotaMeterPollingRegistry`.
    private let pollingID = UUID()

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, opencodeIndexer: OpenCodeSessionIndexer,
         activeCodex: CodexActiveSessionsModel, codexUsage: CodexUsageModel, claudeUsage: ClaudeUsageModel) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.opencodeIndexer = opencodeIndexer
        self.activeCodex = activeCodex
        self.codexUsage = codexUsage
        self.claudeUsage = claudeUsage
    }

    /// Shows the strip on the given screen, rebuilding it if the screen or its geometry changed.
    func present(on screenID: UInt32) {
        guard let screen = NSScreen.screens.first(where: { Self.displayID($0) == screenID }) else {
            dismiss()
            return
        }
        let layout = QuotaStripGeometry.layout(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width, auxRightWidth: screen.auxiliaryTopRightArea?.width)
        if isPresented, self.screenID == screenID, let model,
           model.notchWidth == layout.notch.width, model.notchHeight == layout.notch.height {
            reposition(on: screen, layout: layout)
            return
        }
        dismiss()
        build(on: screen, layout: layout)
        self.screenID = screenID
        isPresented = true
        // The strip polls in the background while it is on screen, mounted content or not.
        QuotaMeterPollingRegistry.set(pollingID, .strip)
    }

    func dismiss() {
        QuotaMeterPollingRegistry.set(pollingID, nil)
        hoverTimer?.invalidate()
        hoverTimer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        sizeObservation = nil
        styleObservation = nil
        popoverObservation = nil
        panel?.orderOut(nil)
        // Removing the content view runs SwiftUI's onDisappear, so the mounted Quota Meter
        // unregisters its consumers before the panel goes away.
        panel?.contentView = nil
        panel?.close()
        panel = nil
        host = nil
        model = nil
        currentLayout = nil
        pointerInside = false
        isPresented = false
        screenID = nil
    }

    // MARK: - Building

    private func build(on screen: NSScreen, layout: QuotaStripLayout) {
        let model = QuotaStripModel(notchWidth: layout.notch.width, notchHeight: layout.notch.height)
        // Set before any hit rect is computed (the first `updatePointer` below).
        model.minimal = Self.minimalStyle
        // Loaded for as long as the strip is on screen, like the floating window, so hovering
        // shows current sessions and runway at once; hidden parts pause their animations.
        model.contentMounted = true
        self.model = model
        let hud = AgentCockpitHUDView(codexIndexer: codexIndexer, claudeIndexer: claudeIndexer,
                                      opencodeIndexer: opencodeIndexer, surface: .strip)
            .environment(activeCodex)
            .environmentObject(codexUsage)
            .environmentObject(claudeUsage)
        let root = QuotaStripRootView(model: model, expandedContent: hud)
            .environment(activeCodex)
            .environmentObject(codexUsage)
            .environmentObject(claudeUsage)
        let host = QuotaStripHostingView(rootView: AnyView(root))
        host.hitRectProvider = { [weak model] in model?.hitRect ?? .zero }
        // The controller owns the panel frame (pinned top-centre); the hosting view must not
        // resize the window from its bottom-left origin.
        host.sizingOptions = []
        self.host = host

        let panel = QuotaStripPanel(contentRect: frame(for: model, on: screen, layout: layout),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        // While the panel takes events, pointer moves over its transparent area arrive here
        // rather than at the global monitor; they must still update hover and pass-through.
        panel.acceptsMouseMovedEvents = true
        panel.contentView = host
        self.panel = panel

        currentLayout = layout
        // The expanded size is measured after layout; keep the panel pinned top-centre on the
        // layout current at that moment (a display rearrangement repositions without a rebuild).
        sizeObservation = AnyCancellableBox(model.$expandedContentSize.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let model = self.model, let layout = self.currentLayout,
                      let screen = self.currentScreen(), let panel = self.panel else { return }
                let target = self.frame(for: model, on: screen, layout: layout)
                // Grow at once so the animating shape has room; shrink after the shape's
                // animation, so it is never clipped by a panel that got smaller first. Axes are
                // handled independently: a growing axis grows now even when the other shrinks.
                let current = panel.frame
                let interimSize = CGSize(width: max(current.width, target.width),
                                         height: max(current.height, target.height))
                let interim = CGRect(x: (layout.notch.midX - interimSize.width / 2).rounded(),
                                     y: screen.frame.maxY - interimSize.height,
                                     width: interimSize.width, height: interimSize.height)
                panel.setFrame(interim, display: true)
                if interim.size != target.size {
                    let shrinkDelay = QuotaStripRootView<EmptyView>.shrinkDelay
                    DispatchQueue.main.asyncAfter(deadline: .now() + shrinkDelay) { [weak self] in
                        guard let self, let model = self.model, let layout = self.currentLayout,
                              let screen = self.currentScreen() else { return }
                        self.panel?.setFrame(self.frame(for: model, on: screen, layout: layout), display: true)
                    }
                }
            }
        })

        // When a toolbar popover closes (by any means, including a click elsewhere in this
        // app), re-check the pointer at once instead of waiting for the next mouse move.
        popoverObservation = AnyCancellableBox(model.$toolbarPopoverOpen.dropFirst().sink { [weak self] open in
            guard !open else { return }
            DispatchQueue.main.async { self?.updatePointer() }
        })

        // Wings / Minimal can change in Settings while the strip is up.
        styleObservation = AnyCancellableBox(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let model = self.model, model.minimal != Self.minimalStyle else { return }
                    withAnimation(Self.closeSpring) { model.minimal = Self.minimalStyle }
                    self.updatePointer()
                }
            })
        monitorMouse()
        panel.orderFrontRegardless()
        updatePointer()
    }

    private func reposition(on screen: NSScreen, layout: QuotaStripLayout) {
        guard let model, let panel else { return }
        currentLayout = layout
        panel.setFrame(frame(for: model, on: screen, layout: layout), display: true)
        panel.orderFrontRegardless()
        updatePointer()
    }

    private func frame(for model: QuotaStripModel, on screen: NSScreen, layout: QuotaStripLayout) -> CGRect {
        let size = model.panelSize
        return CGRect(x: (layout.notch.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func currentScreen() -> NSScreen? {
        NSScreen.screens.first { Self.displayID($0) == screenID }
    }

    private static var minimalStyle: Bool {
        QuotaMeterNotchStyle.current(raw: UserDefaults.standard.string(forKey: PreferencesKey.quotaMeterNotchStyle)) == .minimal
    }

    static func displayID(_ screen: NSScreen) -> UInt32? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // MARK: - Pointer

    private func monitorMouse() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer() }
            return event
        }) { mouseMonitors.append(local) }
        // Clicks on the collapsed strip, or on the notch row of the open panel, open the menu.
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { (self?.handleClick(event) ?? false) ? nil : event }
        }) { mouseMonitors.append(clicks) }
        // A click in another app closes the open panel, even when a toolbar popover is up
        // (a transient popover from a non-activating panel may not close by itself).
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, model.expanded else { return }
                self.hoverTimer?.invalidate()
                model.toolbarPopoverOpen = false
                self.setExpanded(false)
            }
        }) { mouseMonitors.append(outside) }
    }

    private func shapeScreenRect() -> CGRect? {
        guard let panel, let model, panel.isVisible else { return nil }
        let r = model.hitRect
        return CGRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func updatePointer() {
        let inside = shapeScreenRect()?.contains(NSEvent.mouseLocation) ?? false
        panel?.ignoresMouseEvents = !inside
        guard inside != pointerInside else {
            // A toolbar popover held the panel open while the pointer was outside; once it
            // closes, the next pointer move starts the close.
            if !inside, let model, model.expanded, hoverTimer?.isValid != true, !isPopoverOpen {
                scheduleClose()
            }
            return
        }
        pointerInside = inside
        hoverTimer?.invalidate()
        guard let model else { return }
        if inside {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            guard !model.expanded else { return }
            scheduleHover(after: Self.openDelay) { [weak self] in self?.setExpanded(true) }
        } else if model.expanded, !isPopoverOpen {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        scheduleHover(after: Self.closeDelay) { [weak self] in
            guard let self else { return }
            // A popover opened from the right-click toolbar keeps the panel open.
            if self.isPopoverOpen { return }
            self.setExpanded(false)
        }
    }

    /// A popover from the expanded panel's own toolbar is on screen (it lives outside the
    /// shape). Reported by the Quota Meter view through the model.
    private var isPopoverOpen: Bool {
        model?.toolbarPopoverOpen ?? false
    }

    private func scheduleHover(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        // Common modes: the timer must also fire while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// Opens the panel for `duration` seconds, then closes it as a hover-out would, unless
    /// the pointer is inside by then (hover handling then owns it). Used after the notch
    /// intro moves the Quota Meter here, so the user sees where it went.
    func peek(duration: TimeInterval) {
        guard isPresented, let model, !model.expanded else { return }
        // The close timer must exist before the panel opens: `updatePointer` otherwise sees
        // an open panel with no timer and the pointer outside, and closes it at once.
        scheduleHover(after: duration) { [weak self] in
            guard let self, !self.pointerInside, !self.isPopoverOpen else { return }
            self.setExpanded(false)
        }
        setExpanded(true)
    }

    private func setExpanded(_ expanded: Bool) {
        guard let model, model.expanded != expanded else { return }
        withAnimation(expanded ? Self.openSpring : Self.closeSpring) { model.expanded = expanded }
        updatePointer()
    }

    private func handleClick(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let host, let model else { return false }
        let point = host.topLeft(host.convert(event.locationInWindow, from: nil))
        guard model.hitRect.contains(point) else { return false }
        let inNotchRow = point.y <= model.notchHeight
        // With a toolbar popover open, let the click just close it: collapsing the panel now
        // would leave the popover anchored to a toolbar that is no longer visible.
        guard !isPopoverOpen else { return false }
        guard !model.expanded || inNotchRow, let menu = menuProvider?() else { return false }
        hoverTimer?.invalidate()
        // Drop the menu the way a status item does: flush under the menu bar, from the
        // panel's collapsed shape, never from the bottom of an open panel.
        setExpanded(false)
        let shape = model.hitRect
        let x: CGFloat
        if point.x < shape.midX - model.notchWidth / 2 {
            x = shape.minX                                  // left wing: left edges meet
        } else if point.x > shape.midX + model.notchWidth / 2 {
            x = shape.maxX - menu.size.width                // right wing: right edges meet
        } else {
            x = shape.midX - menu.size.width / 2            // the notch: centred under it
        }
        let anchor = NSPoint(x: x, y: model.notchHeight)
        menu.popUp(positioning: nil, at: host.isFlipped ? anchor : NSPoint(x: anchor.x, y: host.bounds.height - anchor.y),
                   in: host)
        // The menu cancelled the hover timer; start the hover state over so it re-arms.
        pointerInside = false
        updatePointer()
        return true
    }
}

/// Holds a Combine subscription without importing Combine at every call site.
private final class AnyCancellableBox {
    private let cancel: () -> Void
    init<C: Cancellable>(_ cancellable: C) { cancel = { cancellable.cancel() } }
    deinit { cancel() }
}
