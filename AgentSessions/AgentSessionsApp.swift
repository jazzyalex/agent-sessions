import SwiftUI
import AppKit
import Combine

@main
struct AgentSessionsApp: App {
    @StateObject private var indexer = SessionIndexer()
    @StateObject private var claudeIndexer = ClaudeSessionIndexer()
    @StateObject private var codexUsageModel = CodexUsageModel.shared
    @StateObject private var claudeUsageModel = ClaudeUsageModel.shared
    @StateObject private var geminiIndexer = GeminiSessionIndexer()
    @StateObject private var updaterController = {
        let controller = UpdaterController()
        UpdaterController.shared = controller
        return controller
    }()
    @StateObject private var unifiedIndexerHolder = _UnifiedHolder()
    @State private var statusItemController: StatusItemController? = nil
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("LayoutMode") private var layoutModeRaw: String = LayoutMode.vertical.rawValue
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("CodexUsageEnabled") private var codexUsageEnabledPref: Bool = false
    @AppStorage("ClaudeUsageEnabled") private var claudeUsageEnabledPref: Bool = false
    @AppStorage("ShowClaudeUsageStrip") private var showClaudeUsageStrip: Bool = false
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

    var body: some Scene {
        // Default unified window
        WindowGroup("Agent Sessions") {
            UnifiedSessionsView(unified: unifiedIndexerHolder.makeUnified(codexIndexer: indexer, claudeIndexer: claudeIndexer, geminiIndexer: geminiIndexer),
                                codexIndexer: indexer,
                                claudeIndexer: claudeIndexer,
                                geminiIndexer: geminiIndexer,
                                analyticsReady: analyticsReady,
                                layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                                onToggleLayout: {
                                    let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                                    layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                                })
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
                .environmentObject(indexer.columnVisibility)
                .environmentObject(updaterController)
                .background(WindowAutosave(name: "MainWindow"))
                .onAppear {
                    guard !AppRuntime.isRunningTests else { return }
                    // Build or refresh analytics index at launch
                    Task.detached(priority: FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated) {
                        do {
                            let db = try IndexDB()
                            let indexer = AnalyticsIndexer(db: db)
                            if try await db.isEmpty() {
                                await indexer.fullBuild()
                            } else {
                                await indexer.refresh()
                            }
                        } catch {
                            print("[Indexing] Launch indexing failed: \(error)")
                        }
                    }

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
                    statusItemController?.setEnabled(newValue)
                    updateUsageModels()
                }
                .onAppear {
                    guard !AppRuntime.isRunningTests else { return }
                    if statusItemController == nil {
                        statusItemController = StatusItemController(indexer: indexer,
                                                                     codexStatus: codexUsageModel,
                                                                     claudeStatus: claudeUsageModel)
                    }
                    statusItemController?.setEnabled(menuBarEnabled)
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
                Button("Find in Transcript") { /* unified find focuses handled in view */ }.keyboardShortcut("f", modifiers: .command).disabled(true)
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { PreferencesWindowController.shared.show(indexer: indexer, updaterController: updaterController) }.keyboardShortcut(",", modifiers: .command) }
            // View menu with Favorites Only toggle (stateful)
            CommandMenu("View") {
                // Bind through UserDefaults so it persists; also forward to unified when it changes
                FavoritesOnlyToggle(unifiedHolder: unifiedIndexerHolder)
            }
        }

        // Legacy windows removed; Unified is the single window.
        
        // No additional scenes
    }
}

// Helper to hold and lazily build unified indexer once
final class _UnifiedHolder: ObservableObject {
    // Internal cache only; no need to publish during view updates
    var unified: UnifiedSessionIndexer? = nil
    func makeUnified(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, geminiIndexer: GeminiSessionIndexer) -> UnifiedSessionIndexer {
        if let u = unified { return u }
        let u = UnifiedSessionIndexer(codexIndexer: codexIndexer, claudeIndexer: claudeIndexer, geminiIndexer: geminiIndexer)
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
            Text("Favorites Only")
        }
    }
}

extension AgentSessionsApp {
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
        codexUsageModel.setEnabled(codexEnabled)

        let claudeEnabled: Bool = {
            if d.object(forKey: "ClaudeUsageEnabled") == nil {
                // default to previous behavior tied to ShowClaudeUsageStrip
                let def = d.bool(forKey: "ShowClaudeUsageStrip")
                d.set(def, forKey: "ClaudeUsageEnabled")
                return def
            }
            return d.bool(forKey: "ClaudeUsageEnabled")
        }()
        claudeUsageModel.setEnabled(claudeEnabled)
    }

    private func setupAnalytics() {
        if AppRuntime.isRunningTests { return }
        guard analyticsService == nil else { return }

        // Create analytics service with indexers
        let service = AnalyticsService(
            codexIndexer: indexer,
            claudeIndexer: claudeIndexer,
            geminiIndexer: geminiIndexer
        )
        analyticsService = service
        analyticsReady = service.isReady
        analyticsReadyObserver = service.$isReady
            .receive(on: RunLoop.main)
            .sink { ready in
                self.analyticsReady = ready
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
