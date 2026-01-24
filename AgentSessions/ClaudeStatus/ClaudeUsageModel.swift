import Foundation
import SwiftUI
import AppKit

// Snapshot of parsed values from Claude CLI /usage
struct ClaudeUsageSnapshot: Equatable {
    var sessionRemainingPercent: Int = 0
    var sessionResetText: String = ""
    var weekAllModelsRemainingPercent: Int = 0
    var weekAllModelsResetText: String = ""
    var weekOpusRemainingPercent: Int? = nil
    var weekOpusResetText: String? = nil

    // MARK: - Helper Methods for UI Display
    // Server now reports "remaining" but UI may want to show "used" (e.g., progress bars)

    func sessionPercentUsed() -> Int {
        return 100 - sessionRemainingPercent
    }

    func weekAllModelsPercentUsed() -> Int {
        return 100 - weekAllModelsRemainingPercent
    }

    func weekOpusPercentUsed() -> Int? {
        guard let remaining = weekOpusRemainingPercent else { return nil }
        return 100 - remaining
    }
}

@MainActor
final class ClaudeUsageModel: ObservableObject {
    static let shared = ClaudeUsageModel()

    @Published var sessionRemainingPercent: Int = 0
    @Published var sessionResetText: String = ""
    @Published var weekAllModelsRemainingPercent: Int = 0
    @Published var weekAllModelsResetText: String = ""
    @Published var weekOpusRemainingPercent: Int? = nil
    @Published var weekOpusResetText: String? = nil
    @Published var lastUpdate: Date? = nil
    @Published var cliUnavailable: Bool = false
    @Published var tmuxUnavailable: Bool = false
    @Published var loginRequired: Bool = false
    @Published var setupRequired: Bool = false
    @Published var setupHint: String? = nil
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil

    private var service: ClaudeStatusService?
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false
    private var wakeObservers: [NSObjectProtocol] = []

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setVisible(_ visible: Bool) {
        // Back-compat shim: treat as strip visibility
        setStripVisible(visible)
    }

    func setStripVisible(_ visible: Bool) {
        stripVisible = visible
        propagateVisibility()
    }

    func setMenuVisible(_ visible: Bool) {
        menuVisible = visible
        propagateVisibility()
    }

    private func propagateVisibility() {
        let union = stripVisible || menuVisible
        let svc = self.service
        Task.detached {
            await svc?.setVisible(union)
        }
    }

    func refreshNow() {
        guard isEnabled else { return }
        if isUpdating { return }
        isUpdating = true
        let svc = self.service
        Task.detached {
            await svc?.refreshNow()
            try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
            await MainActor.run {
                if ClaudeUsageModel.shared.isUpdating { ClaudeUsageModel.shared.isUpdating = false }
            }
        }
    }

    private func start() {
        let model = self
        let handler: @Sendable (ClaudeUsageSnapshot) -> Void = { snapshot in
            Task { @MainActor in
                // Avoid publishing changes during SwiftUI view updates (can happen when the menu bar
                // or strip visibility flips and the service immediately delivers a snapshot).
                await Task.yield()
                model.apply(snapshot)
            }
        }
        let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
            Task { @MainActor in
                // Avoid publishing changes during SwiftUI view updates.
                await Task.yield()
                model.cliUnavailable = availability.cliUnavailable
                model.tmuxUnavailable = availability.tmuxUnavailable
                model.loginRequired = availability.loginRequired
                model.setupRequired = availability.setupRequired
                model.setupHint = availability.setupHint
            }
        }
        let service = ClaudeStatusService(updateHandler: handler, availabilityHandler: availabilityHandler)
        self.service = service
        installWakeObservers()
        Task.detached {
            await service.start()
        }
        propagateVisibility()
    }

    private func stop() {
        Task.detached { [service] in
            await service?.stop()
        }
        service = nil
        removeWakeObservers()
    }

    private func installWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        wakeObservers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWake()
                }
            }
        )
        wakeObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWake()
                }
            }
        )
    }

    private func removeWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in wakeObservers {
            nc.removeObserver(token)
        }
        wakeObservers.removeAll()
    }

    private func handleWake() {
        guard isEnabled else { return }
        guard stripVisible || menuVisible else { return }
        if UserDefaults.standard.bool(forKey: PreferencesKey.claudeUsageEnabled) == false { return }
        refreshNow()
    }

    // Hard-probe entry: run a one-off /usage probe and return diagnostics
    func hardProbeNowDiagnostics(completion: @escaping (ClaudeProbeDiagnostics) -> Void) {
        guard isEnabled else {
            let diag = ClaudeProbeDiagnostics(
                success: false,
                exitCode: 125,
                scriptPath: "(not run)",
                workdir: ClaudeProbeConfig.probeWorkingDirectory(),
                claudeBin: nil,
                tmuxBin: nil,
                timeoutSecs: nil,
                stdout: "",
                stderr: "Claude usage tracking is disabled"
            )
            completion(diag)
            return
        }
        if isUpdating { return }
        isUpdating = true
        Task { [weak self] in
            guard let self else { return }
            if let svc = self.service {
                let diag = await svc.forceProbeNow()
                await MainActor.run {
                    if diag.success {
                        self.lastSuccessAt = Date()
                        setFreshUntil(for: .claude, until: Date().addingTimeInterval(60 * 60))
                    }
                    self.isUpdating = false
                    completion(diag)
                }
                return
            }
            let handler: @Sendable (ClaudeUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in
                    // Avoid publishing changes during SwiftUI view updates.
                    await Task.yield()
                    self.apply(snapshot)
                }
            }
            let availability: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
                Task { @MainActor in
                    // Avoid publishing changes during SwiftUI view updates.
                    await Task.yield()
                    self.cliUnavailable = availability.cliUnavailable
                    self.tmuxUnavailable = availability.tmuxUnavailable
                    self.loginRequired = availability.loginRequired
                    self.setupRequired = availability.setupRequired
                    self.setupHint = availability.setupHint
                }
            }
            let svc = ClaudeStatusService(updateHandler: handler, availabilityHandler: availability)
            let diag = await svc.forceProbeNow()
            await MainActor.run {
                if diag.success {
                    self.lastSuccessAt = Date()
                    setFreshUntil(for: .claude, until: Date().addingTimeInterval(60 * 60))
                }
                self.isUpdating = false
                completion(diag)
            }
        }
    }

    private func apply(_ s: ClaudeUsageSnapshot) {
        sessionRemainingPercent = clampPercent(s.sessionRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weekAllModelsRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)
        sessionResetText = s.sessionResetText
        weekAllModelsResetText = s.weekAllModelsResetText
        weekOpusResetText = s.weekOpusResetText
        lastUpdate = Date()
        if isUpdating { isUpdating = false }
    }

    private func clampPercent(_ v: Int) -> Int { max(0, min(100, v)) }
}

struct ClaudeServiceAvailability {
    var cliUnavailable: Bool
    var tmuxUnavailable: Bool
    var loginRequired: Bool = false
    var setupRequired: Bool = false
    var setupHint: String? = nil
}
