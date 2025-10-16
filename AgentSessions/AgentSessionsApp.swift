import SwiftUI
import AppKit

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
    @AppStorage("ShowClaudeUsageStrip") private var showClaudeUsageStrip: Bool = false
    @AppStorage("UnifiedLegacyNoticeShown") private var unifiedNoticeShown: Bool = false
    @State private var selectedSessionID: String?
    @State private var selectedEventID: String?
    @State private var focusSearchToggle: Bool = false
    // Legacy first-run prompt removed

    var body: some Scene {
        // Default unified window
        WindowGroup("Agent Sessions") {
            UnifiedSessionsView(unified: unifiedIndexerHolder.makeUnified(codexIndexer: indexer, claudeIndexer: claudeIndexer, geminiIndexer: geminiIndexer),
                                codexIndexer: indexer,
                                claudeIndexer: claudeIndexer,
                                geminiIndexer: geminiIndexer,
                                layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                                onToggleLayout: {
                                    let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                                    layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                                })
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
                .environmentObject(updaterController)
                .background(WindowAutosave(name: "MainWindow"))
                .onAppear {
                    unifiedIndexerHolder.unified?.refresh()
                    updateUsageModels()
                }
                .onChange(of: showUsageStrip) { _, _ in
                    updateUsageModels()
                }
                .onChange(of: menuBarEnabled) { _, newValue in
                    statusItemController?.setEnabled(newValue)
                    updateUsageModels()
                }
                .onAppear {
                    if statusItemController == nil {
                        statusItemController = StatusItemController(indexer: indexer,
                                                                     codexStatus: codexUsageModel,
                                                                     claudeStatus: claudeUsageModel)
                    }
                    statusItemController?.setEnabled(menuBarEnabled)
                }
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
        // Codex usage model is independent of Claude experimental flag
        let codexOn = menuBarEnabled || showUsageStrip
        codexUsageModel.setEnabled(codexOn)

        // Claude usage must be explicitly allowed via "Activate Claude usage"
        let claudeExperimental = d.bool(forKey: "ShowClaudeUsageStrip")
        claudeUsageModel.setEnabled(claudeExperimental)
    }
}
// (Legacy ContentView and FirstRunPrompt removed)
