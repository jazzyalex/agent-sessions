import Foundation

// MARK: - Tmux Fallback Adapter
//
// Wraps the existing ClaudeStatusService to produce ClaudeLimitSnapshot output.
// No behavior changes to ClaudeStatusService — this is a thin translation layer.
// Activated by ClaudeUsageSourceManager when OAuth fails repeatedly or mode is tmuxOnly.

actor ClaudeTmuxUsageFallbackAdapter {
    typealias SnapshotHandler = @Sendable (ClaudeLimitSnapshot) -> Void
    typealias AvailabilityHandler = @Sendable (ClaudeServiceAvailability) -> Void

    private var service: ClaudeStatusService?
    private var snapshotHandler: SnapshotHandler?
    private var availabilityHandler: AvailabilityHandler?

    func start(
        handler: @escaping SnapshotHandler,
        availabilityHandler: @escaping AvailabilityHandler
    ) {
        self.snapshotHandler = handler
        self.availabilityHandler = availabilityHandler

        let onSnapshot: @Sendable (ClaudeUsageSnapshot) -> Void = { [weak self] tmuxSnapshot in
            Task { [weak self] in
                guard let self else { return }
                let normalized = await self.convert(tmuxSnapshot)
                handler(normalized)
            }
        }
        let onAvailability: @Sendable (ClaudeServiceAvailability) -> Void = { a in
            availabilityHandler(a)
        }

        let svc = ClaudeStatusService(updateHandler: onSnapshot, availabilityHandler: onAvailability)
        self.service = svc
        Task.detached {
            await svc.start()
        }
    }

    func stop() async {
        await service?.stop()
        service = nil
        snapshotHandler = nil
        availabilityHandler = nil
    }

    func setVisibility(menuVisible: Bool, stripVisible: Bool, appIsActive: Bool) {
        let svc = service
        Task.detached {
            await svc?.setVisibility(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
        }
    }

    func refreshNow() {
        let svc = service
        Task.detached {
            await svc?.refreshNow()
        }
    }

    func forceProbeNow() async -> ClaudeProbeDiagnostics? {
        guard let svc = service else { return nil }
        return await svc.forceProbeNow()
    }

    // MARK: - Conversion

    private func convert(_ s: ClaudeUsageSnapshot) -> ClaudeLimitSnapshot {
        let fiveHourRatio = Double(100 - max(0, min(100, s.sessionRemainingPercent))) / 100.0
        let weeklyRatio = Double(100 - max(0, min(100, s.weekAllModelsRemainingPercent))) / 100.0
        let weekOpusRatio: Double? = s.weekOpusRemainingPercent.map { r in
            Double(100 - max(0, min(100, r))) / 100.0
        }

        return ClaudeLimitSnapshot(
            fetchedAt: Date(),
            source: .tmuxUsage,
            health: .live,
            fiveHourUsedRatio: fiveHourRatio,
            fiveHourResetText: s.sessionResetText,
            weeklyUsedRatio: weeklyRatio,
            weeklyResetText: s.weekAllModelsResetText,
            weekOpusUsedRatio: weekOpusRatio,
            weekOpusResetText: s.weekOpusResetText,
            rawPayloadHash: nil
        )
    }
}
