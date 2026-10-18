import AppKit
import NotchSpikeCore

/// Show new, then hide old. The old presentation is hidden only after the new
/// one is observed visible; a visibility timeout is a failure. Overlap is
/// measured with one instrument on both sides: old observed hidden minus new
/// observed visible (occlusion notifications).
@MainActor
final class SpikeHandoff {
    enum Presentation: String { case notch, floating }

    private let controller: SpikeController
    private let log: SpikeLog
    private let openStandIn: () -> Bool
    private var busy = false
    private var observers: [NSObjectProtocol] = []
    private var startedAt = Date()
    private var standInWindow: NSWindow?
    private(set) var presentation: Presentation = .notch

    init(controller: SpikeController, log: SpikeLog, openStandIn: @escaping () -> Bool) {
        self.controller = controller
        self.log = log
        self.openStandIn = openStandIn
    }

    func toFloating() {
        guard begin(.floating) else { return }
        let wasVisible = standInWindows().contains { $0.isVisible }
        let wait = VisibilityWait()
        observe(wantVisible: true, wait: wait) { [weak self] window in
            guard window.identifier?.rawValue == StandInRouter.identifier else { return false }
            self?.standInWindow = window
            return true
        }
        StandInRouter.expectingOpen = true
        guard openStandIn() else {
            fail("to-floating", reason: "open-unavailable")
            return
        }
        let current = standInWindows().first { $0.isVisible }
        let already = wasVisible && (current?.occlusionState.contains(.visible) ?? false)
        if already { standInWindow = current }
        wait.start(alreadyVisible: already) { [weak self] outcome in
            guard let self else { return }
            self.removeObservers()
            switch outcome {
            case .visible(let source):
                let visibleAt = Date()
                self.log.write("floating.visible", ["source": source])
                guard let wing = self.controller.anyWingPanel() else {
                    self.controller.hideNotchPanels()
                    self.finish("to-floating", to: .floating, visibleAt: visibleAt, hideCall: 0, hiddenAt: nil,
                                hiddenSource: "no-notch-panels")
                    return
                }
                let hidden = VisibilityWait()
                self.observe(wantVisible: false, wait: hidden) { $0 === wing }
                let callStart = Date()
                self.controller.hideNotchPanels()
                let hideCall = Date().timeIntervalSince(callStart)
                self.log.write("notch.out")
                hidden.start(alreadyVisible: !wing.occlusionState.contains(.visible)) { [weak self] result in
                    guard let self else { return }
                    self.removeObservers()
                    self.finish("to-floating", to: .floating, visibleAt: visibleAt, hideCall: hideCall,
                                hiddenAt: result == .timedOut ? nil : Date())
                }
            case .timedOut:
                self.fail("to-floating", reason: "visibility-timeout")
            }
        }
    }

    func toNotch() {
        guard begin(.notch) else { return }
        guard let wing = controller.anyWingPanel() else {
            fail("to-notch", reason: "no-notch-panels")
            return
        }
        let wasVisible = wing.isVisible
        let wait = VisibilityWait()
        observe(wantVisible: true, wait: wait) { $0 === wing }
        controller.showNotchPanels()
        // isVisible flips at once on orderFront; occlusion may be stale, so trust it only if
        // the wing was already on screen before the show call.
        let already = wasVisible && wing.occlusionState.contains(.visible)
        wait.start(alreadyVisible: already) { [weak self] outcome in
            guard let self else { return }
            self.removeObservers()
            switch outcome {
            case .visible(let source):
                let visibleAt = Date()
                self.log.write("notch.visible", ["source": source])
                let targets = Set(self.standInWindows().map(ObjectIdentifier.init))
                    .union([self.standInWindow].compactMap { $0 }.map(ObjectIdentifier.init))
                let windows = NSApp.windows.filter { targets.contains(ObjectIdentifier($0)) }
                let primary = self.standInWindow ?? windows.first { $0.isVisible }
                let hidden = VisibilityWait()
                if let primary { self.observe(wantVisible: false, wait: hidden) { $0 === primary } }
                let callStart = Date()
                windows.forEach { $0.orderOut(nil) }
                let hideCall = Date().timeIntervalSince(callStart)
                hidden.start(alreadyVisible: primary.map { !$0.occlusionState.contains(.visible) } ?? true) {
                    [weak self] result in
                    guard let self else { return }
                    self.removeObservers()
                    let hiddenAt = result == .timedOut ? nil : Date()
                    windows.forEach { $0.close() }
                    StandInRouter.expectingOpen = false
                    self.standInWindow = nil
                    let stillVisible = self.standInWindows().filter { $0.isVisible }.count
                    self.log.write("floating.closed", ["windows": String(windows.count),
                                                       "visible_count": String(stillVisible)])
                    if stillVisible > 0 {
                        self.fail("to-notch", reason: "standin-still-visible")
                        return
                    }
                    self.finish("to-notch", to: .notch, visibleAt: visibleAt, hideCall: hideCall, hiddenAt: hiddenAt)
                }
            case .timedOut:
                self.fail("to-notch", reason: "visibility-timeout")
            }
        }
    }

    // MARK: - Helpers

    private func begin(_ target: Presentation) -> Bool {
        let dir = "to-\(target.rawValue)"
        guard !busy else {
            log.write("handoff.busy", ["dir": dir])
            return false
        }
        guard target != presentation else {
            log.write("handoff.noop", ["dir": dir])
            return false
        }
        busy = true
        startedAt = Date()
        log.write("handoff.start", ["dir": dir])
        return true
    }

    private func finish(_ dir: String, to target: Presentation, visibleAt: Date, hideCall: TimeInterval,
                        hiddenAt: Date?, hiddenSource: String? = nil) {
        presentation = target
        busy = false
        log.write("old.hidden", ["source": hiddenSource ?? (hiddenAt == nil ? "timeout" : "occlusion")])
        log.write("handoff.end", [
            "dir": dir,
            "overlap_ms": hiddenAt.map { Self.ms($0.timeIntervalSince(visibleAt)) } ?? "unknown",
            "hide_call_ms": Self.ms(hideCall),
            "latency_ms": Self.ms(visibleAt.timeIntervalSince(startedAt)),
            "app_active": String(NSApp.isActive),
        ])
        log.write("model.signal", ["visible": "true", "pinned": String(target == .notch)])
    }

    private func fail(_ dir: String, reason: String) {
        removeObservers()
        busy = false
        log.write("handoff.failed", ["dir": dir, "reason": reason])
    }

    private func standInWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == StandInRouter.identifier }
    }

    private func observe(wantVisible: Bool, wait: VisibilityWait, matching: @escaping (NSWindow) -> Bool) {
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      window.occlusionState.contains(.visible) == wantVisible,
                      matching(window) else { return }
                wait.reportVisible()
            }
        }
        observers.append(token)
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}
