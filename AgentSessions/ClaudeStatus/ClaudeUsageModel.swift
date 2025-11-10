import Foundation
import SwiftUI

// Snapshot of parsed values from Claude CLI /usage
struct ClaudeUsageSnapshot: Equatable {
    var sessionPercent: Int = 0
    var sessionResetText: String = ""
    var weekAllModelsPercent: Int = 0
    var weekAllModelsResetText: String = ""
    var weekOpusPercent: Int? = nil
    var weekOpusResetText: String? = nil
}

@MainActor
final class ClaudeUsageModel: ObservableObject {
    static let shared = ClaudeUsageModel()

    @Published var sessionPercent: Int = 0
    @Published var sessionResetText: String = ""
    @Published var weekAllModelsPercent: Int = 0
    @Published var weekAllModelsResetText: String = ""
    @Published var weekOpusPercent: Int? = nil
    @Published var weekOpusResetText: String? = nil
    @Published var lastUpdate: Date? = nil
    @Published var cliUnavailable: Bool = false
    @Published var tmuxUnavailable: Bool = false
    @Published var loginRequired: Bool = false
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil

    private var service: ClaudeStatusService?
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false

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
        Task.detached { [weak self] in
            await self?.service?.setVisible(union)
        }
    }

    func refreshNow() {
        if isUpdating { return }
        isUpdating = true
        Task.detached { [weak self] in
            await self?.service?.refreshNow()
            try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
            await MainActor.run { if self?.isUpdating == true { self?.isUpdating = false } }
        }
    }

    private func start() {
        let model = self
        let handler: @Sendable (ClaudeUsageSnapshot) -> Void = { snapshot in
            Task { @MainActor in
                model.apply(snapshot)
            }
        }
        let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
            Task { @MainActor in
                model.cliUnavailable = availability.cliUnavailable
                model.tmuxUnavailable = availability.tmuxUnavailable
                model.loginRequired = availability.loginRequired
            }
        }
        let service = ClaudeStatusService(updateHandler: handler, availabilityHandler: availabilityHandler)
        self.service = service
        Task.detached {
            await service.start()
        }
    }

    private func stop() {
        Task.detached { [service] in
            await service?.stop()
        }
        service = nil
    }

    // Hard-probe entry: run a one-off /usage probe and return diagnostics
    func hardProbeNowDiagnostics(completion: @escaping (ClaudeProbeDiagnostics) -> Void) {
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
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
                Task { @MainActor in
                    self.cliUnavailable = availability.cliUnavailable
                    self.tmuxUnavailable = availability.tmuxUnavailable
                    self.loginRequired = availability.loginRequired
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
        sessionPercent = clampPercent(s.sessionPercent)
        weekAllModelsPercent = clampPercent(s.weekAllModelsPercent)
        weekOpusPercent = s.weekOpusPercent.map(clampPercent)
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
}
