import Foundation

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var content: OnboardingContent?

    private let defaults: UserDefaults
    private let currentMajorMinorProvider: () -> String?
    private let isFreshInstallProvider: () -> Bool
    private var hasChecked: Bool = false

    init(
        defaults: UserDefaults = .standard,
        currentMajorMinorProvider: @escaping () -> String? = OnboardingContent.currentMajorMinor,
        isFreshInstallProvider: @escaping () -> Bool = OnboardingCoordinator.defaultIsFreshInstall
    ) {
        self.defaults = defaults
        self.currentMajorMinorProvider = currentMajorMinorProvider
        self.isFreshInstallProvider = isFreshInstallProvider
    }

    func checkAndPresentIfNeeded() {
        guard !hasChecked else { return }
        hasChecked = true

        guard let majorMinor = currentMajorMinorProvider() else { return }
        guard let kind = determineAutoTourKind(for: majorMinor) else { return }

        present(kind: kind, majorMinor: majorMinor)
    }

    func presentManually() {
        guard let majorMinor = currentMajorMinorProvider() else { return }
        present(kind: .fullTour, majorMinor: majorMinor)
    }

    func skip() {
        recordActionAndDismiss()
    }

    func complete() {
        recordActionAndDismiss()
    }

    private func determineAutoTourKind(for majorMinor: String) -> OnboardingContent.Kind? {
        if isFreshInstallProvider(), !defaults.onboardingFullTourCompleted {
            return .fullTour
        }

        if defaults.onboardingLastActionMajorMinor != majorMinor {
            return .updateTour
        }

        return nil
    }

    private func present(kind: OnboardingContent.Kind, majorMinor: String) {
        switch kind {
        case .fullTour:
            content = OnboardingContent.fullTour(for: majorMinor)
        case .updateTour:
            content = OnboardingContent.updateTour(for: majorMinor) ?? OnboardingContent.fallbackUpdateTour(for: majorMinor)
        }
        isPresented = true
    }

    private func recordActionAndDismiss() {
        if let majorMinor = content?.versionMajorMinor {
            defaults.onboardingLastActionMajorMinor = majorMinor

            if content?.kind == .fullTour {
                defaults.onboardingFullTourCompleted = true
            }
        }
        isPresented = false
    }
}

extension OnboardingCoordinator {
    nonisolated static func defaultIsFreshInstall() -> Bool {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let dbURL = appSupport
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("index.db", isDirectory: false)
        return !fm.fileExists(atPath: dbURL.path)
    }
}
