import SwiftUI
import AppKit

@main
struct AgentSessionsApp: App {
    @StateObject private var indexer = SessionIndexer()
    @StateObject private var claudeIndexer = ClaudeSessionIndexer()
    @StateObject private var codexUsageModel = CodexUsageModel.shared
    @StateObject private var claudeUsageModel = ClaudeUsageModel.shared
    @StateObject private var updateModel = UpdateCheckModel.shared
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
    @State private var showUpdateAlert: Bool = false
    @State private var updateAlertData: (version: String, releaseURL: String, assetURL: String)? = nil
    // Legacy first-run prompt removed

    var body: some Scene {
        // Default unified window
        WindowGroup("Agent Sessions") {
            UnifiedSessionsView(unified: unifiedIndexerHolder.makeUnified(codexIndexer: indexer, claudeIndexer: claudeIndexer),
                                codexIndexer: indexer,
                                claudeIndexer: claudeIndexer,
                                layoutMode: LayoutMode(rawValue: layoutModeRaw) ?? .vertical,
                                onToggleLayout: {
                                    let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                                    layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
                                })
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
                .onAppear {
                    indexer.refresh(); claudeIndexer.refresh()
                    updateUsageModels()
                    updateModel.checkOnLaunch()
                }
                .onChange(of: showUsageStrip) { _, _ in
                    updateUsageModels()
                }
                .onChange(of: menuBarEnabled) { _, newValue in
                    statusItemController?.setEnabled(newValue)
                    updateUsageModels()
                }
                .onChange(of: updateModel.state) { _, newState in
                    if case .available(let version, let releaseURL, let assetURL) = newState {
                        updateAlertData = (version, releaseURL, assetURL)
                        showUpdateAlert = true
                    }
                }
                .onAppear {
                    if statusItemController == nil {
                        statusItemController = StatusItemController(indexer: indexer,
                                                                     codexStatus: codexUsageModel,
                                                                     claudeStatus: claudeUsageModel)
                    }
                    statusItemController?.setEnabled(menuBarEnabled)
                }
                .alert("Update Available", isPresented: $showUpdateAlert) {
                    if let data = updateAlertData {
                        Button("Release Notes") {
                            updateModel.openURL(data.releaseURL)
                        }
                        Button("Download") {
                            updateModel.openURL(data.assetURL)
                        }
                        Button("Skip This Version") {
                            updateModel.skipVersionForLaunchOnly(data.version)
                        }
                        Button("Later", role: .cancel) {}
                    }
                } message: {
                    if let data = updateAlertData {
                        Text("Version \(data.version) is available for download.")
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Agent Sessions") {
                    PreferencesWindowController.shared.show(indexer: indexer, initialTab: .about)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh") { unifiedIndexerHolder.unified?.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("Find in Transcript") { /* unified find focuses handled in view */ }.keyboardShortcut("f", modifiers: .command).disabled(true)
                Divider()
                Button("Check for Updates…") { updateModel.checkManually() }
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { PreferencesWindowController.shared.show(indexer: indexer) }.keyboardShortcut(",", modifiers: .command) }
            CommandGroup(after: .windowArrangement) {
                Button("Codex Only (Unified)") { focusUnified(preset: .codexOnly) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Claude Only (Unified)") { focusUnified(preset: .claudeOnly) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
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
    func makeUnified(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer) -> UnifiedSessionIndexer {
        if let u = unified { return u }
        let u = UnifiedSessionIndexer(codexIndexer: codexIndexer, claudeIndexer: claudeIndexer)
        unified = u
        return u
    }
}

// Window helpers
extension AgentSessionsApp {
    enum UnifiedPreset { case codexOnly, claudeOnly, both }
    private func focusUnified(preset: UnifiedPreset) {
        // Ensure Unified indexer exists and set source filters
        let unified = unifiedIndexerHolder.makeUnified(codexIndexer: indexer, claudeIndexer: claudeIndexer)
        switch preset {
        case .codexOnly:
            unified.includeCodex = true; unified.includeClaude = false
        case .claudeOnly:
            unified.includeCodex = false; unified.includeClaude = true
        case .both:
            unified.includeCodex = true; unified.includeClaude = true
        }
        unified.recomputeNow()

        // Bring Unified window to front (create if none by activating the app)
        NSApp.activate(ignoringOtherApps: true)

        // One-time notice replacing legacy windows
        if !unifiedNoticeShown {
            unifiedNoticeShown = true
            let alert = NSAlert()
            alert.messageText = "Unified Window"
            alert.informativeText = "Legacy Codex/Claude windows have been replaced by the Unified window. Use Shift+Cmd+1 for Codex only, Shift+Cmd+2 for Claude only."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

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
