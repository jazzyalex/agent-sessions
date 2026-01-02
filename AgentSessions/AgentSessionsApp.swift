import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    static let openSessionsSearchFromMenu = Notification.Name("AgentSessionsOpenSessionsSearchFromMenu")
    static let openTranscriptFindFromMenu = Notification.Name("AgentSessionsOpenTranscriptFindFromMenu")
    static let showOnboardingFromMenu = Notification.Name("AgentSessionsShowOnboardingFromMenu")
}

@main
struct AgentSessionsApp: App {
    @StateObject private var indexer = SessionIndexer()
    @StateObject private var claudeIndexer = ClaudeSessionIndexer()
    @StateObject private var opencodeIndexer = OpenCodeSessionIndexer()
    @StateObject private var archiveManager = SessionArchiveManager.shared
    @StateObject private var codexUsageModel = CodexUsageModel.shared
    @StateObject private var claudeUsageModel = ClaudeUsageModel.shared
    @StateObject private var geminiIndexer = GeminiSessionIndexer()
    @StateObject private var copilotIndexer = CopilotSessionIndexer()
    @StateObject private var droidIndexer = DroidSessionIndexer()
    @StateObject private var updaterController = {
        let controller = UpdaterController()
        UpdaterController.shared = controller
        return controller
    }()
    @StateObject private var onboardingCoordinator = OnboardingCoordinator()
    @StateObject private var unifiedIndexerHolder = _UnifiedHolder()
    @State private var statusItemController: StatusItemController? = nil
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("LayoutMode") private var layoutModeRaw: String = LayoutMode.horizontal.rawValue
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("CodexUsageEnabled") private var codexUsageEnabledPref: Bool = false
    @AppStorage("ClaudeUsageEnabled") private var claudeUsageEnabledPref: Bool = false
    @AppStorage("ShowClaudeUsageStrip") private var showClaudeUsageStrip: Bool = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.geminiEnabled) private var geminiAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @AppStorage("UnifiedLegacyNoticeShown") private var unifiedNoticeShown: Bool = false
    @State private var selectedSessionID: String?
    @State private var selectedEventID: String?
    @State private var focusSearchToggle: Bool = false
    // Legacy first-run prompt removed

    // Analytics
    @State private var analyticsService: AnalyticsService?
    @State private var analyticsWindowController: AnalyticsWindowController?
    @State private var analyticsReady: Bool = false
    @State private var analyticsReadyObserver: AnyCancellable?

    init() {
        AgentEnablement.seedIfNeeded()
    }

    var body: some Scene {
        // Default unified window
        WindowGroup("Agent Sessions") {
            let unified = unifiedIndexerHolder.makeUnified(
                codexIndexer: indexer,
                claudeIndexer: claudeIndexer,
                geminiIndexer: geminiIndexer,
                opencodeIndexer: opencodeIndexer,
                copilotIndexer: copilotIndexer,
                droidIndexer: droidIndexer
            )
            let layoutMode = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
            UnifiedSessionsView(
                unified: unified,
                codexIndexer: indexer,
                claudeIndexer: claudeIndexer,
                geminiIndexer: geminiIndexer,
                opencodeIndexer: opencodeIndexer,
                copilotIndexer: copilotIndexer,
                droidIndexer: droidIndexer,
                analyticsReady: analyticsReady,
                layoutMode: layoutMode,
                onToggleLayout: {
                    let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                    layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                }
            )
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
                .environmentObject(indexer.columnVisibility)
                .environmentObject(archiveManager)
                .environmentObject(updaterController)
                .background(WindowAutosave(name: "MainWindow"))
                .onAppear {
                    guard !AppRuntime.isRunningTests else { return }
                    LaunchProfiler.reset("Unified main window")
                    LaunchProfiler.log("Window appeared")
                    LaunchProfiler.log("UnifiedSessionIndexer.refresh() invoked")
                    onboardingCoordinator.checkAndPresentIfNeeded()
                    unifiedIndexerHolder.unified?.refresh()
                    updateUsageModels()
                    setupAnalytics()
                }
                .onChange(of: showUsageStrip) { _, _ in
                    updateUsageModels()
                }
                .onChange(of: codexUsageEnabledPref) { _, _ in
                    updateUsageModels()
                }
                .onChange(of: claudeUsageEnabledPref) { _, _ in
                    updateUsageModels()
                }
                .onChange(of: menuBarEnabled) { _, newValue in
                    updateUsageModels()
                }
                .onChange(of: codexAgentEnabled) { _, _ in handleAgentEnablementChange() }
                .onChange(of: claudeAgentEnabled) { _, _ in handleAgentEnablementChange() }
                .onChange(of: geminiAgentEnabled) { _, _ in handleAgentEnablementChange() }
                .onChange(of: openCodeAgentEnabled) { _, _ in handleAgentEnablementChange() }
                .onAppear {
                    guard !AppRuntime.isRunningTests else { return }
                    if statusItemController == nil {
                        statusItemController = StatusItemController(indexer: indexer,
                                                                     codexStatus: codexUsageModel,
                                                                     claudeStatus: claudeUsageModel)
                    }
                    updateUsageModels()
                }
                .onReceive(NotificationCenter.default.publisher(for: .showOnboardingFromMenu)) { _ in
                    onboardingCoordinator.presentManually()
                }
                .sheet(isPresented: $onboardingCoordinator.isPresented) {
                    Group {
                        if let content = onboardingCoordinator.content {
                            OnboardingSheetView(content: content, coordinator: onboardingCoordinator)
                        }
                    }
                }
                // Immediate cleanup happens after each probe; no app-exit cleanup required.
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Agent Sessions") {
                    PreferencesWindowController.shared.show(indexer: indexer, updaterController: updaterController, initialTab: .about)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider()
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh") { unifiedIndexerHolder.unified?.refresh() }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { PreferencesWindowController.shared.show(indexer: indexer, updaterController: updaterController) }.keyboardShortcut(",", modifiers: .command) }
            CommandMenu("Search") {
                Button("Search Sessions…") {
                    NotificationCenter.default.post(name: .openSessionsSearchFromMenu, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("Search in Transcript…") {
                    NotificationCenter.default.post(name: .openTranscriptFindFromMenu, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            // View menu with Saved Only toggle (stateful)
            CommandMenu("View") {
                Button("Toggle Dark/Light") { indexer.toggleDarkLightUsingSystemAppearance() }
                Button("Use System Appearance") { indexer.useSystemAppearance() }
                    .disabled((AppAppearance(rawValue: appAppearanceRaw) ?? .system) == .system)
                Divider()
                // Bind through UserDefaults so it persists; also forward to unified when it changes
                FavoritesOnlyToggle(unifiedHolder: unifiedIndexerHolder)
                Divider()
                OpenPinnedSessionsWindowButton()
            }
            CommandGroup(after: .help) {
                Button("Onboarding…") {
                    NotificationCenter.default.post(name: .showOnboardingFromMenu, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }

        WindowGroup("Saved Sessions", id: "PinnedSessions") {
            PinnedSessionsView(
                unified: unifiedIndexerHolder.makeUnified(
                    codexIndexer: indexer,
                    claudeIndexer: claudeIndexer,
                    geminiIndexer: geminiIndexer,
                    opencodeIndexer: opencodeIndexer,
                    copilotIndexer: copilotIndexer,
                    droidIndexer: droidIndexer
                )
            )
            .environmentObject(archiveManager)
        }

        // Legacy windows removed; Unified is the single window.
        
        // No additional scenes
    }
}

// Helper to hold and lazily build unified indexer once
final class _UnifiedHolder: ObservableObject {
    // Internal cache only; no need to publish during view updates
    var unified: UnifiedSessionIndexer? = nil
    func makeUnified(codexIndexer: SessionIndexer,
                     claudeIndexer: ClaudeSessionIndexer,
                     geminiIndexer: GeminiSessionIndexer,
                     opencodeIndexer: OpenCodeSessionIndexer,
                     copilotIndexer: CopilotSessionIndexer,
                     droidIndexer: DroidSessionIndexer) -> UnifiedSessionIndexer {
        if let u = unified { return u }
        let u = UnifiedSessionIndexer(codexIndexer: codexIndexer,
                                      claudeIndexer: claudeIndexer,
                                      geminiIndexer: geminiIndexer,
                                      opencodeIndexer: opencodeIndexer,
                                      copilotIndexer: copilotIndexer,
                                      droidIndexer: droidIndexer)
        unified = u
        return u
    }
}

// MARK: - View Menu Toggle Wrapper
private struct FavoritesOnlyToggle: View {
    @AppStorage("ShowFavoritesOnly") private var favsOnly: Bool = false
    @ObservedObject var unifiedHolder: _UnifiedHolder

    var body: some View {
        Toggle(isOn: Binding(
            get: { favsOnly },
            set: { newVal in
                favsOnly = newVal
                unifiedHolder.unified?.showFavoritesOnly = newVal
            }
        )) {
            Text("Saved Only")
        }
    }
}

private struct OpenPinnedSessionsWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Saved Sessions…") {
            openWindow(id: "PinnedSessions")
        }
        .keyboardShortcut("p", modifiers: [.command, .option, .shift])
    }
}

extension AgentSessionsApp {
    private func handleAgentEnablementChange() {
        unifiedIndexerHolder.unified?.recomputeNow()
        analyticsService?.refreshReadiness()
        updateUsageModels()
    }

    private func updateUsageModels() {
        let d = UserDefaults.standard
        // Migration defaults on first run of new toggles
        let codexEnabled: Bool = {
            if d.object(forKey: "CodexUsageEnabled") == nil {
                // default to previous implicit behavior: on when either strip or menu bar shown
                let def = menuBarEnabled || showUsageStrip
                d.set(def, forKey: "CodexUsageEnabled")
                return def
            }
            return d.bool(forKey: "CodexUsageEnabled")
        }()
        codexUsageModel.setEnabled(codexEnabled && codexAgentEnabled)

        let claudeEnabled: Bool = {
            if d.object(forKey: "ClaudeUsageEnabled") == nil {
                // default to previous behavior tied to ShowClaudeUsageStrip
                let def = d.bool(forKey: "ShowClaudeUsageStrip")
                d.set(def, forKey: "ClaudeUsageEnabled")
                return def
            }
            return d.bool(forKey: "ClaudeUsageEnabled")
        }()
        claudeUsageModel.setEnabled(claudeEnabled && claudeAgentEnabled)

        let anyUsageAgentEnabled = (codexAgentEnabled || claudeAgentEnabled)
        statusItemController?.setEnabled(menuBarEnabled && anyUsageAgentEnabled)
    }

    private func setupAnalytics() {
        if AppRuntime.isRunningTests { return }
        guard analyticsService == nil else { return }

        // Create analytics service with indexers
        let service = AnalyticsService(
            codexIndexer: indexer,
            claudeIndexer: claudeIndexer,
            geminiIndexer: geminiIndexer,
            opencodeIndexer: opencodeIndexer,
            copilotIndexer: copilotIndexer
        )
        analyticsService = service

        // Gate readiness on both analytics warmup and unified analytics indexing.
        if let unified = unifiedIndexerHolder.unified {
            analyticsReady = service.isReady && !unified.isAnalyticsIndexing
            analyticsReadyObserver = service.$isReady
                .combineLatest(unified.$isAnalyticsIndexing)
                .receive(on: RunLoop.main)
                .sink { ready, indexing in
                    self.analyticsReady = ready && !indexing
                    if !indexing {
                        service.refreshReadiness()
                    }
                }
        } else {
            analyticsReady = service.isReady
            analyticsReadyObserver = service.$isReady
                .receive(on: RunLoop.main)
                .sink { ready in
                    self.analyticsReady = ready
                }
        }

        // Create window controller
        let controller = AnalyticsWindowController(service: service)
        analyticsWindowController = controller

        // Observe toggle notifications
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ToggleAnalyticsWindow"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard service.isReady else {
                    NSSound.beep()
                    print("[Analytics] Ignoring toggle – analytics still warming up")
                    return
                }
                controller.toggle()
            }
        }
    }

}
// (Legacy ContentView and FirstRunPrompt removed)
