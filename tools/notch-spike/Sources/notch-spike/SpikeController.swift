import AppKit
import SwiftUI
import NotchSpikeCore

/// One borderless non-activating panel per target screen. The SwiftUI notch shape grows from
/// the collapsed strip into the Quota Meter; clicks outside the shape pass through
/// (`hitTest` limited to the shape, `ignoresMouseEvents` toggled from mouse monitors).
@MainActor
final class SpikeController {
    enum Style: String { case wings, minimal }

    var menuProvider: (() -> NSMenu?)?

    var style: Style = .wings {
        didSet {
            log.write("style", ["value": style.rawValue])
            withAnimation(NotchModel.closeSpring) { model?.minimal = style == .minimal }
            updateMouseState()
        }
    }

    private let log: SpikeLog
    /// Best-in-class timing (boring.notch / codex-island): open after 0.3 s, close 0.1 s after leaving.
    private var dwell = HoverDwell(openDelay: 0.3, closeDelay: 0.1)
    private var timer: Timer?
    private(set) var generation = 0
    private var layout: SpikeLayout?
    private var panel: SpikePanel?
    private var model: NotchModel?
    private var pointerInside = false
    private var everCreated: [(gen: Int, panel: Weak)] = []
    private let screenDebouncer = Debouncer(delay: 0.5)
    private var burst = 0
    private var lastScreensChanged: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseMonitors: [Any] = []

    final class Weak {
        weak var value: SpikePanel?
        init(_ value: SpikePanel) { self.value = value }
    }

    init(log: SpikeLog) {
        self.log = log
    }

    func start() {
        observe()
        monitorMouse()
        build()
    }

    func rebuild(reason: String) {
        log.write("rebuild", ["reason": reason])
        let old = generation
        let count = panel == nil ? 0 : 1
        tearDown()
        log.write("panels.torn-down", ["count": String(count), "gen": String(old)])
        generation += 1
        build()
        log.write("panels.created", ["count": String(panel == nil ? 0 : 1), "gen": String(generation),
                                     "reason": reason, "burst": String(burst)])
        let gen = generation
        // 1 s is an early look; only a stale panel still alive at 5 s counts as a leak.
        for delay in [1.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logAlive(gen: gen, after: delay)
            }
        }
    }

    private func showPanel() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        log.write("panel.placed", ["role": panel.role, "frame": Self.str(panel.frame), "gen": String(generation)])
        updateMouseState()
    }

    // MARK: - Building

    private func tearDown() {
        collapse(reason: "teardown")
        panel?.close()
        panel = nil
        model = nil
        pointerInside = false
    }

    private func build() {
        let notched = Self.notchedScreen()
        guard let screen = notched ?? NSScreen.screens.first else {
            log.write("no-screen")
            layout = nil
            return
        }
        NSScreen.screens.forEach(logScreen)
        let l: SpikeLayout
        let mode: String
        if notched != nil, let notchLayout = SpikeGeometry.layout(
            screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
            auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea) {
            l = notchLayout
            mode = "notch"
        } else {
            l = SpikeGeometry.virtualLayout(screenFrame: screen.frame,
                                            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
            mode = "virtual"
        }
        layout = l
        log.write("layout", ["mode": mode, "notch": Self.str(l.notch), "leftWing": Self.str(l.leftWing),
                             "rightWing": Self.str(l.rightWing), "dropPanel": Self.str(l.dropPanel),
                             "gen": String(generation)])

        let model = NotchModel(notchWidth: l.notch.width, notchHeight: l.notch.height, virtual: mode == "virtual")
        model.minimal = style == .minimal
        self.model = model
        let size = model.panelSize
        let frame = CGRect(x: l.notch.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        let panel = SpikePanel(frame: frame, role: "notch", generation: generation, opaqueBlack: false, log: log)
        let host = NotchHostingView(rootView: NotchRootView(model: model))
        host.hitRectProvider = { [weak model] in model?.hitRect ?? .zero }
        host.onClick = { [weak self] point in self?.click(at: point) }
        host.onRightClick = { [weak self] in self?.log.write("rightClick", self?.clickFields(role: "notch") ?? [:]) }
        panel.contentView = host
        panel.ignoresMouseEvents = true
        everCreated.append((generation, Weak(panel)))
        self.panel = panel
        log.write("expanded.size", ["size": "\(model.expandedSize.width)x\(model.expandedSize.height)",
                                    "panel": Self.str(frame)])
        showPanel()
    }

    private func logAlive(gen: Int, after delay: TimeInterval) {
        everCreated.removeAll { $0.panel.value == nil }
        let current = everCreated.filter { $0.gen == gen }.count
        let stale = everCreated.filter { $0.gen < gen }
        let names = stale.compactMap { $0.panel.value.map { "\($0.role):\($0.generation)" } }
        log.write("panels.alive", ["gen": String(gen), "latest": String(generation), "after_s": String(Int(delay)),
                                   "current": String(current), "stale": String(stale.count),
                                   "stale_list": names.isEmpty ? "-" : names.joined(separator: ",")])
    }

    // MARK: - Pointer

    private func monitorMouse() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouseState() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouseState() }
            return event
        }) { mouseMonitors.append(local) }
    }

    /// Screen rect of the current interactive shape.
    private func shapeScreenRect() -> CGRect? {
        guard let panel, let model, panel.isVisible else { return nil }
        let r = model.hitRect
        return CGRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func updateMouseState() {
        let inside = shapeScreenRect()?.contains(NSEvent.mouseLocation) ?? false
        panel?.ignoresMouseEvents = !inside
        guard inside != pointerInside else { return }
        pointerInside = inside
        let fields = ["role": "strip", "app_active": String(NSApp.isActive)]
        if inside {
            log.write("hover.enter", fields)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            apply(dwell.pointer(entered: "strip"))
        } else {
            log.write("hover.exit", fields)
            apply(dwell.pointer(exited: "strip"))
        }
    }

    private func apply(_ action: HoverDwell.Action) {
        switch action {
        case .none:
            return
        case .cancelTimers:
            timer?.invalidate()
            timer = nil
        case .scheduleOpen(let delay), .scheduleClose(let delay):
            timer?.invalidate()
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.timerFired() }
            }
            // Common modes: the timer must also fire while a menu is tracking.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func timerFired() {
        timer = nil
        guard dwell.timerFired(), let model else { return }
        if dwell.isOpen {
            withAnimation(NotchModel.openSpring) { model.expanded = true }
            log.write("drop.open", ["role": "drop"])
        } else {
            withAnimation(NotchModel.closeSpring) { model.expanded = false }
            log.write("drop.close", ["role": "drop", "reason": "dwell"])
        }
        updateMouseState()
    }

    private func collapse(reason: String) {
        timer?.invalidate()
        timer = nil
        if let model, model.expanded {
            model.expanded = false
            log.write("drop.close", ["role": "drop", "reason": reason])
        }
        dwell = HoverDwell(openDelay: 0.3, closeDelay: 0.1)
    }

    // MARK: - Clicks

    private func clickFields(role: String) -> [String: String] {
        ["role": role, "app_active": String(NSApp.isActive),
         "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"]
    }

    /// Collapsed: any click opens the strip menu. Expanded: a click in the notch row does.
    private func click(at point: NSPoint) {
        guard let model else { return }
        let inNotchRow = point.y <= model.notchHeight
        log.write("click", clickFields(role: model.expanded ? (inNotchRow ? "notch-row" : "panel") : "strip"))
        guard !model.expanded || inNotchRow, let host = panel?.contentView,
              let menu = menuProvider?() ?? nil else { return }
        log.write("menu.open", clickFields(role: "strip"))
        let anchor = NSPoint(x: model.hitRect.minX + 10, y: model.shapeSize.height + 4)
        menu.popUp(positioning: nil, at: anchor, in: host)
        log.write("menu.close", ["app_active": String(NSApp.isActive)])
    }

    // MARK: - Observers

    private func observe() {
        let app = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        add(app, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.screensChanged() }
        add(ws, NSWorkspace.willSleepNotification) { [weak self] in self?.log.write("sleep") }
        add(ws, NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.log.write("wake")
            self.screenDebouncer.call { [weak self] in self?.rebuild(reason: "wake-or-screens") }
        }
        add(app, NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.log.write("app.activated",
                            ["frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"])
        }
        add(app, NSApplication.didResignActiveNotification) { [weak self] in
            self?.log.write("app.deactivated")
        }
        add(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.log.write("space.changed",
                            ["frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"])
        }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
        observers.append((center, token))
    }

    private func screensChanged() {
        let now = Date()
        if let last = lastScreensChanged, now.timeIntervalSince(last) < 0.5 {} else { burst += 1 }
        lastScreensChanged = now
        log.write("screens.changed", ["burst": String(burst), "screens": String(NSScreen.screens.count)])
        screenDebouncer.call { [weak self] in self?.rebuild(reason: "screens") }
    }

    // MARK: - Screens

    static func notchedScreen() -> NSScreen? {
        let notched = NSScreen.screens.filter {
            $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }
        return notched.first(where: isBuiltin) ?? notched.first
    }

    static func isBuiltin(_ screen: NSScreen) -> Bool {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    private func logScreen(_ screen: NSScreen) {
        log.write("screen", ["frame": Self.str(screen.frame), "builtin": String(Self.isBuiltin(screen)),
                             "backingScale": String(describing: screen.backingScaleFactor),
                             "safeTop": String(describing: screen.safeAreaInsets.top),
                             "menuBar": String(describing: screen.frame.maxY - screen.visibleFrame.maxY),
                             "auxLeft": screen.auxiliaryTopLeftArea.map(Self.str) ?? "nil",
                             "auxRight": screen.auxiliaryTopRightArea.map(Self.str) ?? "nil"])
    }

    static func str(_ r: CGRect) -> String {
        "\(r.minX),\(r.minY),\(r.width)x\(r.height)"
    }
}
