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
    private var mouseMonitors: [Any] = []
    private var pointerInside = false
    private var hoverTimer: Timer?
    private var unmountTimer: Timer?
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
        unmountTimer?.invalidate()
        unmountTimer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        sizeObservation = nil
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
                      let screen = self.currentScreen() else { return }
                self.panel?.setFrame(self.frame(for: model, on: screen, layout: layout), display: true)
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
    }

    private func shapeScreenRect() -> CGRect? {
        guard let panel, let model, panel.isVisible else { return nil }
        let r = model.hitRect
        return CGRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func updatePointer() {
        let inside = shapeScreenRect()?.contains(NSEvent.mouseLocation) ?? false
        panel?.ignoresMouseEvents = !inside
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTimer?.invalidate()
        guard let model else { return }
        if inside {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            unmountTimer?.invalidate()
            unmountTimer = nil
            // Mount now, during the open dwell, so the content loads and is measured first.
            if !model.contentMounted { model.contentMounted = true }
            guard !model.expanded else { return }
            scheduleHover(after: Self.openDelay) { [weak self] in self?.setExpanded(true) }
        } else if !model.expanded {
            scheduleUnmount()
        } else {
            scheduleHover(after: Self.closeDelay) { [weak self] in self?.setExpanded(false) }
        }
    }

    private func scheduleHover(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        // Common modes: the timer must also fire while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func setExpanded(_ expanded: Bool) {
        guard let model, model.expanded != expanded else { return }
        withAnimation(expanded ? Self.openSpring : Self.closeSpring) { model.expanded = expanded }
        if !expanded { scheduleUnmount() }
        updatePointer()
    }

    /// Unmounts the Quota Meter content once the close animation has finished, unless the
    /// pointer came back.
    private func scheduleUnmount() {
        unmountTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, !model.expanded, !self.pointerInside else { return }
                model.contentMounted = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        unmountTimer = timer
    }

    private func handleClick(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let host, let model else { return false }
        let point = host.topLeft(host.convert(event.locationInWindow, from: nil))
        guard model.hitRect.contains(point) else { return false }
        let inNotchRow = point.y <= model.notchHeight
        guard !model.expanded || inNotchRow, let menu = menuProvider?() else { return false }
        hoverTimer?.invalidate()
        let anchor = NSPoint(x: model.hitRect.minX + 10, y: model.shapeSize.height + 4)
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
