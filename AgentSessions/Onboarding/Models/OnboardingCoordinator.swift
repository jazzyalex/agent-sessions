import Foundation

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var content: OnboardingContent?

    private let defaults: UserDefaults
    private let currentMajorMinorProvider: () -> String?
    private var hasChecked: Bool = false

    init(defaults: UserDefaults = .standard, currentMajorMinorProvider: @escaping () -> String? = OnboardingContent.currentMajorMinor) {
        self.defaults = defaults
        self.currentMajorMinorProvider = currentMajorMinorProvider
    }

    func checkAndPresentIfNeeded() {
        guard !hasChecked else { return }
        hasChecked = true

        guard let majorMinor = currentMajorMinorProvider() else { return }
        guard shouldAutoPresent(for: majorMinor) else { return }

        present(for: majorMinor)
    }

    func presentManually() {
        guard let majorMinor = currentMajorMinorProvider() else { return }
        present(for: majorMinor)
    }

    func skip() {
        recordActionAndDismiss()
    }

    func complete() {
        recordActionAndDismiss()
    }

    private func shouldAutoPresent(for majorMinor: String) -> Bool {
        defaults.onboardingLastActionMajorMinor != majorMinor
    }

    private func present(for majorMinor: String) {
        content = OnboardingContent.forMajorMinor(majorMinor) ?? OnboardingContent.fallback(for: majorMinor)
        isPresented = true
    }

    private func recordActionAndDismiss() {
        if let majorMinor = content?.versionMajorMinor {
            defaults.onboardingLastActionMajorMinor = majorMinor
        }
        isPresented = false
    }
}
