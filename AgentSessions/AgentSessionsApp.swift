import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let claudeArchiveDidChange = Notification.Name("AgentSessionsClaudeArchiveDidChange")
    static let openSessionsSearchFromMenu = Notification.Name("AgentSessionsOpenSessionsSearchFromMenu")
    static let openTranscriptFindFromMenu = Notification.Name("AgentSessionsOpenTranscriptFindFromMenu")
    static let showOnboardingFromMenu = Notification.Name("AgentSessionsShowOnboardingFromMenu")
    static let showPowerTipsFromMenu = Notification.Name("AgentSessionsShowPowerTipsFromMenu")
    static let showWhatsNewFromMenu = Notification.Name("AgentSessionsShowWhatsNewFromMenu")
    static let navigateToSessionFromImages = Notification.Name("AgentSessionsNavigateToSessionFromImages")
    static let navigateToSessionFromCockpit = Notification.Name("AgentSessionsNavigateToSessionFromCockpit")
    static let navigateToSessionEventFromImages = Notification.Name("AgentSessionsNavigateToSessionEventFromImages")
    static let showImagesFromMenu = Notification.Name("AgentSessionsShowImagesFromMenu")
    static let collapseAllUnifiedSessionGroupsFromMenu = Notification.Name("AgentSessionsCollapseAllUnifiedSessionGroupsFromMenu")
    static let expandAllUnifiedSessionGroupsFromMenu = Notification.Name("AgentSessionsExpandAllUnifiedSessionGroupsFromMenu")
    static let showImagesForInlineImage = Notification.Name("AgentSessionsShowImagesForInlineImage")
    static let selectImagesBrowserItem = Notification.Name("AgentSessionsSelectImagesBrowserItem")
    static let requestCoreIndexRebuild = Notification.Name("AgentSessionsRequestCoreIndexRebuild")
    static let showPreferencesTab = Notification.Name("AgentSessionsShowPreferencesTab")
}

struct PendingCockpitNavigationRequest {
    let unifiedSessionID: String
    let sourceRawValue: String?
    let runtimeSessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let createdAt: Date
}

enum AppWindowRouter {
    @MainActor static var openAgentSessionsWindow: (() -> Void)?
    @MainActor static var openAgentCockpitWindow: (() -> Void)?
    @MainActor private static var didAttemptPinnedCockpitLaunchRestore: Bool = false

    @MainActor private static func existingWindow(title: String, identifier: String? = nil) -> NSWindow? {
        if let identifier {
            if let identifiedWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                return identifiedWindow
            }
        }

        return NSApp.windows.first(where: { $0.title == title })
    }

    @MainActor private static func existingWindow(identifier: String) -> NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    @MainActor static func showAgentSessionsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = existingWindow(title: "Agent Sessions") {
            main.makeKeyAndOrderFront(nil)
            return
        }
        if let openAgentSessionsWindow {
            openAgentSessionsWindow()
            return
        }
    }

    @MainActor static var isAgentSessionsWindowVisible: Bool {
        existingWindow(title: "Agent Sessions")?.isVisible ?? false
    }

    @MainActor static func closeAgentSessionsWindow() {
        existingWindow(title: "Agent Sessions")?.close()
    }

    @MainActor static func showAgentCockpitWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let cockpit = existingWindow(identifier: "AgentCockpit") {
            cockpit.makeKeyAndOrderFront(nil)
            return
        }
        if let openAgentCockpitWindow {
            openAgentCockpitWindow()
            return
        }
    }

    @MainActor static var isAgentCockpitWindowVisible: Bool {
        existingWindow(identifier: "AgentCockpit")?.isVisible ?? false
    }

    @MainActor static func closeAgentCockpitWindow() {
        existingWindow(identifier: "AgentCockpit")?.close()
    }

    @MainActor
    static func shouldRestorePinnedCockpitOnLaunch(defaults: UserDefaults = .standard) -> Bool {
        let liveSessionsEnabled = defaults.object(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) as? Bool ?? true
        guard liveSessionsEnabled else { return false }
        return defaults.object(forKey: PreferencesKey.Cockpit.hudPinned) as? Bool ?? false
    }

    @MainActor
    static func maybeRestorePinnedCockpitOnLaunch(openWindow: () -> Void) {
        guard !didAttemptPinnedCockpitLaunchRestore else { return }
        didAttemptPinnedCockpitLaunchRestore = true
        guard !AppRuntime.isRunningTests else { return }
        guard shouldRestorePinnedCockpitOnLaunch() else { return }
        guard existingWindow(identifier: "AgentCockpit") == nil else { return }
        openWindow()
    }
}

enum CockpitNavigationBridge {
    private static let defaultsKey = "AgentSessionsPendingCockpitNavigationRequest"
    private static let unifiedSessionIDKey = "unifiedSessionID"
    private static let sourceRawValueKey = "sourceRawValue"
    private static let runtimeSessionIDKey = "runtimeSessionID"
    private static let logPathKey = "logPath"
    private static let workingDirectoryKey = "workingDirectory"
    private static let createdAtKey = "createdAtEpoch"

    static func store(_ request: PendingCockpitNavigationRequest) {
        let payload: [String: Any] = [
            unifiedSessionIDKey: request.unifiedSessionID,
            sourceRawValueKey: request.sourceRawValue ?? "",
            runtimeSessionIDKey: request.runtimeSessionID ?? "",
            logPathKey: request.logPath ?? "",
            workingDirectoryKey: request.workingDirectory ?? "",
            createdAtKey: request.createdAt.timeIntervalSince1970
        ]
        UserDefaults.standard.set(payload, forKey: defaultsKey)
    }

    static func load() -> PendingCockpitNavigationRequest? {
        guard let payload = UserDefaults.standard.dictionary(forKey: defaultsKey),
              let unifiedSessionID = payload[unifiedSessionIDKey] as? String,
              !unifiedSessionID.isEmpty,
              let createdAtEpoch = payload[createdAtKey] as? TimeInterval else {
            return nil
        }

        func optionalValue(for key: String) -> String? {
            guard let raw = payload[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return PendingCockpitNavigationRequest(
            unifiedSessionID: unifiedSessionID,
            sourceRawValue: optionalValue(for: sourceRawValueKey),
            runtimeSessionID: optionalValue(for: runtimeSessionIDKey),
            logPath: optionalValue(for: logPathKey),
            workingDirectory: optionalValue(for: workingDirectoryKey),
            createdAt: Date(timeIntervalSince1970: createdAtEpoch)
        )
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static func clearIfMatching(unifiedSessionID: String) {
        guard let pending = load() else { return }
        guard pending.unifiedSessionID == unifiedSessionID else { return }
        clear()
    }

    static func hasPending(unifiedSessionID: String) -> Bool {
        load()?.unifiedSessionID == unifiedSessionID
    }
}

@main
struct AgentSessionsApp: App {
    @NSApplicationDelegateAdaptor(AgentSessionsApplicationDelegate.self) private var appDelegate
    @StateObject private var indexer = SessionIndexer()
    @StateObject private var claudeIndexer = ClaudeSessionIndexer()
    @StateObject private var opencodeIndexer = OpenCodeSessionIndexer()
    @StateObject private var archiveManager = SessionArchiveManager.shared
    @StateObject private var codexUsageModel = CodexUsageModel.shared
    @StateObject private var claudeUsageModel = ClaudeUsageModel.shared
    @State private var activeCodexSessions = CodexActiveSessionsModel()
    @StateObject private var antigravityIndexer = AntigravitySessionIndexer()
    @StateObject private var hermesIndexer = HermesSessionIndexer()
    @StateObject private var copilotIndexer = CopilotSessionIndexer()
    @StateObject private var droidIndexer = DroidSessionIndexer()
    @StateObject private var openclawIndexer = OpenClawSessionIndexer()
    @StateObject private var cursorIndexer = CursorSessionIndexer()
    @StateObject private var piIndexer = PiSessionIndexer()
    @StateObject private var updaterController = UpdaterController()
    @StateObject private var onboardingCoordinator = OnboardingCoordinator()
    @StateObject private var unifiedIndexerHolder = _UnifiedHolder()
    @State private var statusItemController: StatusItemController? = nil
    @State private var analyticsToggleObserver: NSObjectProtocol?
    @State private var mainWindowCloseObserver: NSObjectProtocol?
    @State private var menuBarDefaultsObserver: NSObjectProtocol?
    @State private var lastObservedMenuBarEnabled: Bool?
    @State private var lastObservedHideDockIcon: Bool?
    @State private var lastObservedPinnedCockpitAvailable: Bool?
    @State private var didRestoreDockForUnavailableMenuBar: Bool = false
    @State private var didRunStartupTasks: Bool = false
    @State private var isDockRecentCleanupScheduled: Bool = false
    private let onboardingWindowPresenter = OnboardingWindowPresenter()
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("LayoutMode") private var layoutModeRaw: String = LayoutMode.vertical.rawValue
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Unified.showTranscriptWindow) private var showTranscriptWindow: Bool = true
    @AppStorage("CodexUsageEnabled") private var codexUsageEnabledPref: Bool = false
    @AppStorage("ClaudeUsageEnabled") private var claudeUsageEnabledPref: Bool = false
    @AppStorage("ShowClaudeUsageStrip") private var showClaudeUsageStrip: Bool = false
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var liveSessionsEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.antigravityEnabled) private var antigravityAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.openCodeEnabled) private var openCodeAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.hermesEnabled) private var hermesAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.piEnabled) private var piAgentEnabled: Bool = AgentEnablement.isEnabled(.pi)
    @AppStorage(PreferencesKey.Advanced.hideDockIcon) private var hideDockIcon: Bool = false
    @AppStorage("UnifiedLegacyNoticeShown") private var unifiedNoticeShown: Bool = false
    @State private var selectedSessionID: String?
    @State private var selectedEventID: String?
    @State private var focusSearchToggle: Bool = false
    // Legacy first-run prompt removed

    // Analytics
    @State private var analyticsService: AnalyticsService?
    @State private var analyticsWindowController: AnalyticsWindowController?
    @State private var analyticsReady: Bool = false
    @State private var analyticsPhase: AnalyticsIndexPhase = .idle
    @State private var analyticsStale: Bool = false
    @State private var analyticsReadyObserver: AnyCancellable?
    @State private var analyticsPhaseObserver: AnyCancellable?
    @State private var analyticsStaleObserver: AnyCancellable?
    @State private var analyticsProgressObserver: AnyCancellable?
    @State private var analyticsLastBuiltObserver: AnyCancellable?
    @State private var analyticsBuildObserver: NSObjectProtocol?
    @State private var analyticsCancelObserver: NSObjectProtocol?
    @State private var analyticsUpdateObserver: NSObjectProtocol?

    init() {
        guard !AppRuntime.isRunningTests else { return }
#if DEBUG
        // Beachball watchdog for the "make every action instant" perf pass (lever #0).
        DispatchQueue.main.async { MainThreadStallMonitor.shared.start() }
        // Self-driving perf harness (no-op unless AS_PERF_BENCH env var is set).
        DispatchQueue.main.async { PerfBench.startIfRequested() }
#endif
        let defaults = UserDefaults.standard
        DockIconPreferenceController.reconcileReachability(defaults: defaults)
        let hideDockIcon = defaults.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false
        let menuBarEnabled = defaults.object(forKey: PreferencesKey.menuBarEnabled) as? Bool ?? false
        let pinnedCockpitAvailable = DockIconPreferenceController.isPinnedCockpitAvailable(defaults: defaults)
        Self.applyActivationPolicy(
            hideDockIcon: hideDockIcon,
            menuBarEnabled: menuBarEnabled,
            pinnedCockpitAvailable: pinnedCockpitAvailable
        )

        // Fallback: if no window appears within 3 seconds, open the gate anyway
        // so startup tasks are never blocked indefinitely in a windowless launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppReadyGate.markReady() }
    }

    @ViewBuilder
    private var unifiedWindowRoot: some View {
        if AppRuntime.isRunningTests {
            EmptyView()
        } else {
            let unified = unifiedIndexerHolder.makeUnified(
                codexIndexer: indexer,
                claudeIndexer: claudeIndexer,
                antigravityIndexer: antigravityIndexer,
                opencodeIndexer: opencodeIndexer,
                hermesIndexer: hermesIndexer,
                copilotIndexer: copilotIndexer,
                droidIndexer: droidIndexer,
                openclawIndexer: openclawIndexer,
                cursorIndexer: cursorIndexer,
                piIndexer: piIndexer
            )
            configuredUnifiedWindow(unified: unified)
        }
    }

    @ViewBuilder
    private func configuredUnifiedWindow(unified: UnifiedSessionIndexer) -> some View {
        let layoutMode = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
        UnifiedSessionsView(
            unified: unified,
            codexIndexer: indexer,
            claudeIndexer: claudeIndexer,
            antigravityIndexer: antigravityIndexer,
            opencodeIndexer: opencodeIndexer,
            hermesIndexer: hermesIndexer,
            copilotIndexer: copilotIndexer,
            droidIndexer: droidIndexer,
            openclawIndexer: openclawIndexer,
            cursorIndexer: cursorIndexer,
            piIndexer: piIndexer,
            analyticsReady: analyticsReady,
            analyticsPhase: analyticsPhase,
            analyticsIsStale: analyticsStale,
            layoutMode: layoutMode,
            onToggleLayout: {
                let current = LayoutMode(rawValue: layoutModeRaw) ?? .vertical
                layoutModeRaw = (current == .vertical ? LayoutMode.horizontal : .vertical).rawValue
            }
        )
        .environmentObject(codexUsageModel)
        .environmentObject(claudeUsageModel)
        .environment(activeCodexSessions)
        .environmentObject(indexer.columnVisibility)
        .environmentObject(archiveManager)
        .environmentObject(updaterController)
        .environmentObject(onboardingCoordinator)
        .background(WindowAutosave(name: "MainWindow"))
        .background(WindowOpenRegistrationView())
        .onAppear {
            runSharedLaunchBootstrap(windowLabel: "Unified main window")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            handleAppDidBecomeActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            handleAppDidResignActive()
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
            handleMenuBarEnabledChange(newValue)
        }
        .onChange(of: liveSessionsEnabled) { _, _ in
            DockIconPreferenceController.reconcileReachability()
            updateUsageModels()
        }
        .onChange(of: hideDockIcon) { _, newValue in
            applyActivationPolicyAndCleanupIfNeeded(hideDockIcon: newValue, menuBarEnabled: menuBarEnabled)
            updateUsageModels()
        }
        .onChange(of: codexAgentEnabled) { _, _ in handleAgentEnablementChange() }
        .onChange(of: claudeAgentEnabled) { _, _ in handleAgentEnablementChange() }
        .onChange(of: antigravityAgentEnabled) { _, _ in handleAgentEnablementChange() }
        .onChange(of: openCodeAgentEnabled) { _, _ in handleAgentEnablementChange() }
        .onChange(of: piAgentEnabled) { _, _ in handleAgentEnablementChange() }
        .onAppear {
            guard !AppRuntime.isRunningTests else { return }
            applyActivationPolicyAndCleanupIfNeeded(hideDockIcon: hideDockIcon, menuBarEnabled: menuBarEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboardingFromMenu)) { _ in
            onboardingCoordinator.presentManually()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPowerTipsFromMenu)) { _ in
            onboardingCoordinator.presentPowerTips()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWhatsNewFromMenu)) { _ in
            onboardingCoordinator.presentWhatsNewFromMenu()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestCoreIndexRebuild)) { _ in
            unified.rebuildCoreIndex()
        }
        .onChange(of: onboardingCoordinator.presentation) { _, presentation in
            if let presentation {
                onboardingWindowPresenter.show(
                    presentation: presentation,
                    coordinator: onboardingCoordinator,
                    codexIndexer: indexer,
                    claudeIndexer: claudeIndexer,
                    antigravityIndexer: antigravityIndexer,
                    opencodeIndexer: opencodeIndexer,
                    hermesIndexer: hermesIndexer,
                    copilotIndexer: copilotIndexer,
                    droidIndexer: droidIndexer,
                    openclawIndexer: openclawIndexer,
                    cursorIndexer: cursorIndexer,
                    piIndexer: piIndexer,
                    codexUsageModel: codexUsageModel,
                    claudeUsageModel: claudeUsageModel
                )
            } else {
                onboardingWindowPresenter.hide()
            }
        }
    }

    var body: some Scene {
        // Default unified window
        WindowGroup("Agent Sessions", id: "Agent Sessions") {
            unifiedWindowRoot
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

                Button("Find in Transcript…") {
                    NotificationCenter.default.post(name: .openTranscriptFindFromMenu, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!showTranscriptWindow)
            }
            // View menu with Saved Only toggle (stateful)
            CommandMenu("View") {
                OpenAgentCockpitWindowButton()
                Button("Image Browser") {
                    NotificationCenter.default.post(name: .showImagesFromMenu, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option, .shift])
                OpenPinnedSessionsWindowButton()
                Divider()
                // Bind through UserDefaults so it persists; also forward to unified when it changes
                FavoritesOnlyToggle(unifiedHolder: unifiedIndexerHolder)
                Toggle("Transcript Window", isOn: $showTranscriptWindow)
                Divider()
                Button("Collapse All") {
                    NotificationCenter.default.post(name: .collapseAllUnifiedSessionGroupsFromMenu, object: nil)
                }
                Button("Expand All") {
                    NotificationCenter.default.post(name: .expandAllUnifiedSessionGroupsFromMenu, object: nil)
                }
                Button("Toggle Dark/Light") { indexer.toggleDarkLightUsingSystemAppearance() }
                Button("Use System Appearance") { indexer.useSystemAppearance() }
                    .disabled((AppAppearance(rawValue: appAppearanceRaw) ?? .system) == .system)
            }
            CommandGroup(after: .help) {
                Button("Power Tips") {
                    NotificationCenter.default.post(name: .showPowerTipsFromMenu, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("What's New") {
                    NotificationCenter.default.post(name: .showWhatsNewFromMenu, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Show Onboarding") {
                    NotificationCenter.default.post(name: .showOnboardingFromMenu, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }

        WindowGroup("Saved Sessions", id: "PinnedSessions") {
            if AppRuntime.isRunningTests {
                EmptyView()
            } else {
                PinnedSessionsView(
                    unified: unifiedIndexerHolder.makeUnified(
                        codexIndexer: indexer,
                        claudeIndexer: claudeIndexer,
                        antigravityIndexer: antigravityIndexer,
                        opencodeIndexer: opencodeIndexer,
                        hermesIndexer: hermesIndexer,
                        copilotIndexer: copilotIndexer,
                        droidIndexer: droidIndexer,
                        openclawIndexer: openclawIndexer,
                        cursorIndexer: cursorIndexer,
                        piIndexer: piIndexer
                    )
                )
                .environmentObject(archiveManager)
                .background(WindowOpenRegistrationView())
                .onAppear {
                    runSharedLaunchBootstrap(windowLabel: "Saved Sessions window")
                }
            }
        }

        Window("Agent Cockpit", id: "AgentCockpit") {
            if AppRuntime.isRunningTests {
                EmptyView()
            } else {
                AgentCockpitHUDView(
                    codexIndexer: indexer,
                    claudeIndexer: claudeIndexer,
                    opencodeIndexer: opencodeIndexer
                )
                .environment(activeCodexSessions)
                .environmentObject(codexUsageModel)
                .environmentObject(claudeUsageModel)
                .background(WindowOpenRegistrationView())
                .onAppear {
                    runSharedLaunchBootstrap(windowLabel: "Agent Cockpit window")
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    handleAppDidBecomeActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    handleAppDidResignActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: .showPreferencesTab)) { note in
                    let raw = note.userInfo?["tab"] as? String
                    let tab = raw.flatMap(PreferencesTab.init(rawValue:)) ?? .general
                    PreferencesWindowController.shared.show(
                        indexer: indexer,
                        updaterController: updaterController,
                        initialTab: tab
                    )
                }
            }
        }
        .defaultSize(width: 644, height: 320)
    }
}

// Helper to hold and lazily build unified indexer once
final class _UnifiedHolder: ObservableObject {
    // Internal cache only; no need to publish during view updates
    var unified: UnifiedSessionIndexer? = nil
    func makeUnified(codexIndexer: SessionIndexer,
                     claudeIndexer: ClaudeSessionIndexer,
                     antigravityIndexer: AntigravitySessionIndexer,
                     opencodeIndexer: OpenCodeSessionIndexer,
                     hermesIndexer: HermesSessionIndexer,
                     copilotIndexer: CopilotSessionIndexer,
                     droidIndexer: DroidSessionIndexer,
                     openclawIndexer: OpenClawSessionIndexer,
                     cursorIndexer: CursorSessionIndexer,
                     piIndexer: PiSessionIndexer) -> UnifiedSessionIndexer {
        if let u = unified { return u }
        let u = UnifiedSessionIndexer(codexIndexer: codexIndexer,
                                      claudeIndexer: claudeIndexer,
                                      antigravityIndexer: antigravityIndexer,
                                      opencodeIndexer: opencodeIndexer,
                                      hermesIndexer: hermesIndexer,
                                      copilotIndexer: copilotIndexer,
                                      droidIndexer: droidIndexer,
                                      openclawIndexer: openclawIndexer,
                                      cursorIndexer: cursorIndexer,
                                      piIndexer: piIndexer)
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
        .keyboardShortcut("s", modifiers: [.command, .option, .shift])
    }
}

private struct OpenPinnedSessionsWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Saved Sessions") {
            openWindow(id: "PinnedSessions")
        }
        .keyboardShortcut("p", modifiers: [.command, .option, .shift])
    }
}

@MainActor
final class AgentSessionsApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Hide Dock Icon",
            action: #selector(toggleDockIconHiddenFromDockMenu),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func toggleDockIconHiddenFromDockMenu() {
        DockIconPreferenceController.setDockIconHidden(true)
    }
}

private struct OpenAgentCockpitWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var liveSessionsFeatureEnabled: Bool = true
    var body: some View {
        Button("Agent Cockpit") {
            openWindow(id: "AgentCockpit")
        }
        .disabled(!liveSessionsFeatureEnabled)
        .help(
            liveSessionsFeatureEnabled
                ? "Open Agent Cockpit."
                : "Enable Live sessions + Cockpit (Beta) in Settings → Agent Cockpit."
        )
        .keyboardShortcut("c", modifiers: [.command, .option, .shift])
    }
}

extension AgentSessionsApp {
    private static let mainUnifiedWindowTitle = "Agent Sessions"

    private static let crashSupportRecipient = "jazzyalex@gmail.com"
    private static let crashIssueURL = URL(string: "https://github.com/jazzyalex/agent-sessions/issues/new?title=Crash%20Report&body=Please%20attach%20the%20exported%20crash%20report%20JSON%20file%20and%20steps%20to%20reproduce.")!

    private static func applyActivationPolicy(
        hideDockIcon: Bool,
        menuBarEnabled: Bool,
        pinnedCockpitAvailable: Bool = DockIconPreferenceController.isPinnedCockpitAvailable()
    ) {
        let apply: () -> Void = {
            let policy = ActivationPolicyDecider.policy(
                hideDockIcon: hideDockIcon,
                menuBarEnabled: menuBarEnabled,
                pinnedCockpitAvailable: pinnedCockpitAvailable
            )
            NSApplication.shared.setActivationPolicy(policy)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    @MainActor
    private func applyActivationPolicyAndCleanupIfNeeded(hideDockIcon: Bool, menuBarEnabled: Bool) {
        let pinnedCockpitAvailable = DockIconPreferenceController.isPinnedCockpitAvailable()
        Self.applyActivationPolicy(
            hideDockIcon: hideDockIcon,
            menuBarEnabled: menuBarEnabled,
            pinnedCockpitAvailable: pinnedCockpitAvailable
        )
        let policy = ActivationPolicyDecider.policy(
            hideDockIcon: hideDockIcon,
            menuBarEnabled: menuBarEnabled,
            pinnedCockpitAvailable: pinnedCockpitAvailable
        )
        if policy == .accessory {
            scheduleDockRecentCleanup()
        }
    }

    @MainActor
    private func scheduleDockRecentCleanup() {
        guard !isDockRecentCleanupScheduled else { return }
        isDockRecentCleanupScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            DockRecentAppCleaner.removeCurrentAppIfPresent()
            isDockRecentCleanupScheduled = false
        }
    }

    @MainActor
    private func unifiedIndexer() -> UnifiedSessionIndexer {
        unifiedIndexerHolder.makeUnified(
            codexIndexer: indexer,
            claudeIndexer: claudeIndexer,
            antigravityIndexer: antigravityIndexer,
            opencodeIndexer: opencodeIndexer,
            hermesIndexer: hermesIndexer,
            copilotIndexer: copilotIndexer,
            droidIndexer: droidIndexer,
            openclawIndexer: openclawIndexer,
            cursorIndexer: cursorIndexer,
            piIndexer: piIndexer
        )
    }

    @MainActor
    private func runSharedLaunchBootstrap(windowLabel: String) {
        guard !AppRuntime.isRunningTests else { return }
        DispatchQueue.main.async { AppReadyGate.markReady() }
        if UpdaterController.shared == nil || UpdaterController.shared !== updaterController {
            UpdaterController.shared = updaterController
        }
        ensureStatusItemController()
        setupMenuBarDefaultsObserverIfNeeded()
        updateUsageModels()
        // Refresh the runway $-burn price list (read-only GET of a public manifest;
        // no user data sent). Bundled defaults work offline until this lands.
        RunwayPriceTable.shared.refreshInBackground()
        setupMainWindowCloseObserverIfNeeded()

        let unified = unifiedIndexer()
        runStartupTasksIfNeeded(unified: unified, windowLabel: windowLabel)
        synchronizeLiveModelsWithCurrentAppActiveState(unified: unified)
    }

    @MainActor
    private func runStartupTasksIfNeeded(unified: UnifiedSessionIndexer, windowLabel: String) {
        guard !didRunStartupTasks else { return }
        didRunStartupTasks = true
        LaunchProfiler.reset(windowLabel)
        LaunchProfiler.log("Window appeared")
        LaunchProfiler.log("UnifiedSessionIndexer.refresh() invoked")
        onboardingCoordinator.checkAndPresentIfNeeded()
        Task {
            await AppReadyGate.waitUntilReady()
            AgentEnablement.seedIfNeeded()
            AgentEnablement.migrateKnownAvailableProvidersIfNeeded()
            unified.detectNewlyAvailableProviders()
            migrateAnalyticsCacheIfNeeded()
            unified.syncAgentEnablementFromDefaults()
            unified.refresh(trigger: .launch)
            setupAnalytics()
            presentAnalyticsOnDemandNoticeIfNeeded()
        }
        Task.detached(priority: .utility) {
            await AppReadyGate.waitUntilReady()
            await CodexStatusService.cleanupOrphansOnLaunch()
            await ClaudeStatusService.cleanupOrphansOnLaunch()
        }
        Task {
            await AppReadyGate.waitUntilReady()
            let detectedCount = await CrashReportingService.shared.detectAndQueueOnLaunch()
            if detectedCount > 0 {
                await presentCrashRecoveryPrompt(newCrashCount: detectedCount)
            }
        }
    }

    @MainActor
    private func synchronizeLiveModelsWithCurrentAppActiveState(unified: UnifiedSessionIndexer) {
        let isAppActive = NSApp?.isActive ?? true
        unified.setAppActive(isAppActive)
        activeCodexSessions.setAppActive(isAppActive)
        codexUsageModel.setAppActive(isAppActive)
        claudeUsageModel.setAppActive(isAppActive)
    }

    private func migrateAnalyticsCacheIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "AnalyticsOnDemandCacheReset_v1"
        if defaults.bool(forKey: key) { return }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = appSupport.appendingPathComponent("AgentSessions", isDirectory: true)
        let db = dir.appendingPathComponent("index.db", isDirectory: false)
        let wal = dir.appendingPathComponent("index.db-wal", isDirectory: false)
        let shm = dir.appendingPathComponent("index.db-shm", isDirectory: false)
        try? FileManager.default.removeItem(at: db)
        try? FileManager.default.removeItem(at: wal)
        try? FileManager.default.removeItem(at: shm)
        defaults.set(true, forKey: key)
    }

    @MainActor
    private func presentAnalyticsOnDemandNoticeIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "AnalyticsOnDemandNoticeShown_v1"
        if defaults.bool(forKey: key) { return }
        defaults.set(true, forKey: key)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Analytics Is Now On Demand"
        alert.informativeText = """
        Agent Sessions now prioritizes Unified and Cockpit responsiveness.
        Analytics indexing starts only when you open Analytics and press Build.
        """
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    @MainActor
    private func handleAppDidBecomeActive() {
        guard !AppRuntime.isRunningTests else { return }
        unifiedIndexerHolder.unified?.setAppActive(true)
        activeCodexSessions.setAppActive(true)
        codexUsageModel.setAppActive(true)
        claudeUsageModel.setAppActive(true)
        archiveManager.syncPinnedSessionsNow()
    }

    @MainActor
    private func handleAppDidResignActive() {
        guard !AppRuntime.isRunningTests else { return }
        unifiedIndexerHolder.unified?.setAppActive(false)
        activeCodexSessions.setAppActive(false)
        codexUsageModel.setAppActive(false)
        claudeUsageModel.setAppActive(false)
    }

    private func setupMainWindowCloseObserverIfNeeded() {
        guard !AppRuntime.isRunningTests else { return }
        guard mainWindowCloseObserver == nil else { return }

        let unifiedHolder = unifiedIndexerHolder
        let isMainUnifiedWindow: (NSWindow) -> Bool = { window in
            window.title == Self.mainUnifiedWindowTitle
        }

        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let closingWindow = note.object as? NSWindow else { return }
            guard isMainUnifiedWindow(closingWindow) else { return }

            DispatchQueue.main.async {
                let hasRemainingMainWindow = NSApp.windows.contains { window in
                    window !== closingWindow && isMainUnifiedWindow(window)
                }
                guard !hasRemainingMainWindow else { return }
                unifiedHolder.unified?.setFocusedSession(nil)
                unifiedHolder.unified?.setAppActive(false)
            }
        }
    }

    private func handleAgentEnablementChange() {
        guard !AppRuntime.isRunningTests else { return }
        unifiedIndexerHolder.unified?.recomputeNow()
        analyticsService?.refreshReadiness()
        updateUsageModels()
    }

    private func handleMenuBarEnabledChange(_ enabled: Bool) {
        guard !AppRuntime.isRunningTests else { return }
        DockIconPreferenceController.setMenuBarEnabled(enabled)
        let pinnedCockpitAvailable = DockIconPreferenceController.isPinnedCockpitAvailable()
        let effectiveHideDockIcon = (enabled || pinnedCockpitAvailable) ? hideDockIcon : false
        lastObservedMenuBarEnabled = enabled
        lastObservedHideDockIcon = effectiveHideDockIcon
        lastObservedPinnedCockpitAvailable = pinnedCockpitAvailable
        updateUsageModels(menuBarEnabledOverride: enabled)
        applyActivationPolicyAndCleanupIfNeeded(hideDockIcon: effectiveHideDockIcon, menuBarEnabled: enabled)
    }

    @MainActor
    private func handleMenuBarVisibilityChange(_ isVisible: Bool) {
        guard !AppRuntime.isRunningTests else { return }
        if isVisible {
            didRestoreDockForUnavailableMenuBar = false
            return
        }
        guard hideDockIcon, menuBarEnabled, !didRestoreDockForUnavailableMenuBar else { return }
        guard !DockIconPreferenceController.isPinnedCockpitAvailable() else { return }
        didRestoreDockForUnavailableMenuBar = true
        UserDefaults.standard.set(false, forKey: PreferencesKey.Advanced.hideDockIcon)
        Self.applyActivationPolicy(hideDockIcon: false, menuBarEnabled: menuBarEnabled)
        AppWindowRouter.showAgentSessionsWindow()
    }

    private func setupMenuBarDefaultsObserverIfNeeded() {
        guard !AppRuntime.isRunningTests else { return }
        guard menuBarDefaultsObserver == nil else { return }
        let defaults = UserDefaults.standard
        lastObservedMenuBarEnabled = defaults.object(forKey: PreferencesKey.menuBarEnabled) as? Bool ?? false
        lastObservedHideDockIcon = defaults.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false
        lastObservedPinnedCockpitAvailable = DockIconPreferenceController.isPinnedCockpitAvailable(defaults: defaults)

        menuBarDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [self] _ in
            let nextMenuBarEnabled = defaults.object(forKey: PreferencesKey.menuBarEnabled) as? Bool ?? false
            var nextHideDockIcon = defaults.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false
            let nextPinnedCockpitAvailable = DockIconPreferenceController.isPinnedCockpitAvailable(defaults: defaults)
            if !DockIconPreferenceController.hasDockHiddenReachability(defaults: defaults), nextHideDockIcon {
                DockIconPreferenceController.reconcileReachability(defaults: defaults)
                nextHideDockIcon = false
            }

            guard nextMenuBarEnabled != self.lastObservedMenuBarEnabled
                || nextHideDockIcon != self.lastObservedHideDockIcon
                || nextPinnedCockpitAvailable != self.lastObservedPinnedCockpitAvailable else { return }

            self.lastObservedMenuBarEnabled = nextMenuBarEnabled
            self.lastObservedHideDockIcon = nextHideDockIcon
            self.lastObservedPinnedCockpitAvailable = nextPinnedCockpitAvailable
            self.updateUsageModels(menuBarEnabledOverride: nextMenuBarEnabled)
            Task { @MainActor in
                self.applyActivationPolicyAndCleanupIfNeeded(
                    hideDockIcon: nextHideDockIcon,
                    menuBarEnabled: nextMenuBarEnabled
                )
            }
        }
    }

    private func updateUsageModels(menuBarEnabledOverride: Bool? = nil) {
        guard !AppRuntime.isRunningTests else { return }
        let d = UserDefaults.standard
        let effectiveMenuBarEnabled = menuBarEnabledOverride ?? menuBarEnabled
        // Migration defaults on first run of new toggles
        let codexEnabled: Bool = {
            if d.object(forKey: "CodexUsageEnabled") == nil {
                // default to previous implicit behavior: on when either strip or menu bar shown
                let def = effectiveMenuBarEnabled || showUsageStrip
                d.set(def, forKey: "CodexUsageEnabled")
                return def
            }
            return d.bool(forKey: "CodexUsageEnabled")
        }()
        let codexTrackingEnabled = codexEnabled && codexAgentEnabled
        codexUsageModel.setEnabled(codexTrackingEnabled)

        let claudeEnabled: Bool = {
            if d.object(forKey: "ClaudeUsageEnabled") == nil {
                // default to previous behavior tied to ShowClaudeUsageStrip
                let def = d.bool(forKey: "ShowClaudeUsageStrip")
                d.set(def, forKey: "ClaudeUsageEnabled")
                return def
            }
            return d.bool(forKey: "ClaudeUsageEnabled")
        }()
        let claudeTrackingEnabled = claudeEnabled && claudeAgentEnabled
        claudeUsageModel.setEnabled(claudeTrackingEnabled)

        if effectiveMenuBarEnabled {
            ensureStatusItemController()
        }
        statusItemController?.setEnabled(effectiveMenuBarEnabled)
    }

    private func ensureStatusItemController() {
        guard !AppRuntime.isRunningTests else { return }
        guard statusItemController == nil else { return }
        let controller = StatusItemController(indexer: indexer,
                                              claudeIndexer: claudeIndexer,
                                              opencodeIndexer: opencodeIndexer,
                                              activeSessions: activeCodexSessions,
                                              codexStatus: codexUsageModel,
                                              claudeStatus: claudeUsageModel)
        controller.visibilityDidChange = { [self] isVisible in
            handleMenuBarVisibilityChange(isVisible)
        }
        statusItemController = controller
    }

    private func setupAnalytics() {
        if AppRuntime.isRunningTests { return }
        guard analyticsService == nil else { return }
        if let observer = analyticsToggleObserver {
            NotificationCenter.default.removeObserver(observer)
            analyticsToggleObserver = nil
        }
        if let observer = analyticsBuildObserver {
            NotificationCenter.default.removeObserver(observer)
            analyticsBuildObserver = nil
        }
        if let observer = analyticsCancelObserver {
            NotificationCenter.default.removeObserver(observer)
            analyticsCancelObserver = nil
        }
        if let observer = analyticsUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            analyticsUpdateObserver = nil
        }

        // Create analytics service with indexers
        let service = AnalyticsService(
            codexIndexer: indexer,
            claudeIndexer: claudeIndexer,
            antigravityIndexer: antigravityIndexer,
            opencodeIndexer: opencodeIndexer,
            hermesIndexer: hermesIndexer,
            copilotIndexer: copilotIndexer,
            droidIndexer: droidIndexer
        )
        analyticsService = service

        // Relay readiness and analytics phase from unified indexer to the service.
        if let unified = unifiedIndexerHolder.unified {
            analyticsReady = service.isReady
            analyticsReadyObserver = service.$isReady
                .receive(on: RunLoop.main)
                .sink { ready in
                    self.analyticsReady = ready
                }
            // Phase relay — keeps service.analyticsPhase in sync with unified indexer.
            analyticsPhaseObserver = unified.$analyticsPhase
                .receive(on: RunLoop.main)
                .sink { phase in
                    self.analyticsPhase = phase
                    service.analyticsPhase = phase
                    if phase == .ready {
                        service.refreshReadiness()
                    }
                }
            analyticsStaleObserver = unified.$analyticsIsStale
                .receive(on: RunLoop.main)
                .sink { stale in
                    self.analyticsStale = stale
                    service.setAnalyticsStale(stale)
                }
            analyticsProgressObserver = unified.$analyticsBuildProgress
                .receive(on: RunLoop.main)
                .sink { progress in
                    service.setBuildProgress(progress)
                }
            analyticsLastBuiltObserver = unified.$analyticsLastBuiltAt
                .receive(on: RunLoop.main)
                .sink { date in
                    service.setLastBuiltAt(date)
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

        // Observe toggle notifications — always opens the window, regardless of readiness.
        let holder = unifiedIndexerHolder
        analyticsToggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleAnalyticsWindow,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in
                guard let controller else { return }
                controller.toggle()
            }
        }

        // Observe build requests from AnalyticsView.
        analyticsBuildObserver = NotificationCenter.default.addObserver(
            forName: .requestAnalyticsBuild,
            object: nil,
            queue: .main
        ) { [weak holder] _ in
            Task { @MainActor in
                holder?.unified?.startAnalyticsBuild()
            }
        }

        analyticsCancelObserver = NotificationCenter.default.addObserver(
            forName: .cancelAnalyticsBuild,
            object: nil,
            queue: .main
        ) { [weak holder] _ in
            Task { @MainActor in
                holder?.unified?.cancelAnalyticsBuild()
            }
        }

        analyticsUpdateObserver = NotificationCenter.default.addObserver(
            forName: .requestAnalyticsUpdate,
            object: nil,
            queue: .main
        ) { [weak holder] _ in
            Task { @MainActor in
                holder?.unified?.updateAnalyticsNow()
            }
        }
    }

    @MainActor
    private func presentCrashRecoveryPrompt(newCrashCount: Int) async {
        let noun = newCrashCount == 1 ? "report" : "reports"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Crash report detected"
        alert.informativeText = """
        Agent Sessions detected \(newCrashCount) new crash \(noun) from a prior run.
        You can email the report directly or export it and open a GitHub issue:
        https://github.com/jazzyalex/agent-sessions/issues/new
        """
        alert.addButton(withTitle: "Email Crash Report")
        alert.addButton(withTitle: "Export + Open GitHub Issue")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let didOpen = await openCrashReportEmailDraft()
            if didOpen {
                await CrashReportingService.shared.clearPendingReports()
            }
        case .alertSecondButtonReturn:
            let didExport = await exportCrashReportAndOpenIssue()
            if didExport {
                await CrashReportingService.shared.clearPendingReports()
            }
        default:
            break
        }
    }

    @MainActor
    private func openCrashReportEmailDraft() async -> Bool {
        let maybeURL = await CrashReportingService.shared.supportEmailDraftURL(recipient: Self.crashSupportRecipient)
        guard let url = maybeURL else {
            await CrashReportingService.shared.setLastEmailError("Failed to build email draft URL.")
            showCrashPromptError(title: "Unable to Prepare Email", message: "The crash email draft could not be prepared.")
            return false
        }

        if NSWorkspace.shared.open(url) {
            await CrashReportingService.shared.markEmailDraftOpened()
            return true
        } else {
            await CrashReportingService.shared.setLastEmailError("Could not open the default email app.")
            showCrashPromptError(title: "Unable to Open Email App", message: "Please ensure a default email app is configured, or export the report and file a GitHub issue.")
            return false
        }
    }

    @MainActor
    private func exportCrashReportAndOpenIssue() async -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "agent-sessions-crash-report-\(Int(Date().timeIntervalSince1970)).json"

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try await CrashReportingService.shared.exportLatestPendingReport(to: url)
            _ = NSWorkspace.shared.open(Self.crashIssueURL)
            return true
        } catch {
            showCrashPromptError(title: "Export Failed", message: error.localizedDescription)
            return false
        }
    }

    @MainActor
    private func showCrashPromptError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

private struct WindowOpenRegistrationView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppWindowRouter.openAgentSessionsWindow = {
                    openWindow(id: "Agent Sessions")
                }
                let openCockpitWindow = {
                    openWindow(id: "AgentCockpit")
                }
                AppWindowRouter.openAgentCockpitWindow = {
                    openCockpitWindow()
                }
                AppWindowRouter.maybeRestorePinnedCockpitOnLaunch(openWindow: openCockpitWindow)
            }
    }
}
// MARK: - Onboarding window presentation

@MainActor
final class OnboardingWindowPresenter: NSObject, NSWindowDelegate {
    private weak var coordinator: OnboardingCoordinator?
    private var windowController: NSWindowController?
    private var hostingView: AppearanceHostingView?
    private var window: NSWindow?
    private var distributedObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppAppearanceRaw: String = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
    private var state: OnboardingWindowState?

    func show(
        presentation: OnboardingPresentation,
        coordinator: OnboardingCoordinator,
        codexIndexer: SessionIndexer,
        claudeIndexer: ClaudeSessionIndexer,
        antigravityIndexer: AntigravitySessionIndexer,
        opencodeIndexer: OpenCodeSessionIndexer,
        hermesIndexer: HermesSessionIndexer,
        copilotIndexer: CopilotSessionIndexer,
        droidIndexer: DroidSessionIndexer,
        openclawIndexer: OpenClawSessionIndexer,
        cursorIndexer: CursorSessionIndexer,
        piIndexer: PiSessionIndexer,
        codexUsageModel: CodexUsageModel,
        claudeUsageModel: ClaudeUsageModel
    ) {
        self.coordinator = coordinator
        state = OnboardingWindowState(
            presentation: presentation,
            coordinator: coordinator,
            codexIndexer: codexIndexer,
            claudeIndexer: claudeIndexer,
            antigravityIndexer: antigravityIndexer,
            opencodeIndexer: opencodeIndexer,
            hermesIndexer: hermesIndexer,
            copilotIndexer: copilotIndexer,
            droidIndexer: droidIndexer,
            openclawIndexer: openclawIndexer,
            cursorIndexer: cursorIndexer,
            piIndexer: piIndexer,
            codexUsageModel: codexUsageModel,
            claudeUsageModel: claudeUsageModel
        )

        let wrapped = makeRootView()
        if let wc = windowController, let hv = hostingView, let win = window {
            hv.rootView = wrapped
            applyAppearance(forceRedraw: true)
            wc.showWindow(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hv = AppearanceHostingView(rootView: wrapped)
        hv.onAppearanceChanged = { [weak self] in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = hv
        window.title = "Onboarding"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 700))
        window.minSize = NSSize(width: 820, height: 700)
        window.center()
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.hostingView = hv
        self.window = window
        windowController = controller
        applyAppearance(forceRedraw: false)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppearancePreferenceChange()
            }
        }
    }

    func hide() {
        teardownObservers()
        windowController?.close()
    }

    func windowWillClose(_ notification: Notification) {
        teardownObservers()
        hostingView?.onAppearanceChanged = nil
        if coordinator?.presentation != nil {
            coordinator?.skip()
        }
        coordinator = nil
        windowController = nil
        hostingView = nil
        window = nil
        state = nil
    }
}
// (Legacy ContentView and FirstRunPrompt removed)

private struct OnboardingWindowState {
    let presentation: OnboardingPresentation
    let coordinator: OnboardingCoordinator
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    let antigravityIndexer: AntigravitySessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    let hermesIndexer: HermesSessionIndexer
    let copilotIndexer: CopilotSessionIndexer
    let droidIndexer: DroidSessionIndexer
    let openclawIndexer: OpenClawSessionIndexer
    let cursorIndexer: CursorSessionIndexer
    let piIndexer: PiSessionIndexer
    let codexUsageModel: CodexUsageModel
    let claudeUsageModel: ClaudeUsageModel
}

private struct OnboardingWindowRoot: View {
    let state: OnboardingWindowState
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    @ViewBuilder
    private var presentedContent: some View {
        switch state.presentation {
        case .firstRunSetup:
            FirstRunSetupView(
                coordinator: state.coordinator,
                codexIndexer: state.codexIndexer,
                claudeIndexer: state.claudeIndexer,
                antigravityIndexer: state.antigravityIndexer,
                opencodeIndexer: state.opencodeIndexer,
                hermesIndexer: state.hermesIndexer,
                copilotIndexer: state.copilotIndexer,
                droidIndexer: state.droidIndexer,
                openclawIndexer: state.openclawIndexer,
                cursorIndexer: state.cursorIndexer,
                piIndexer: state.piIndexer
            )
        case .powerTips(let content):
            OnboardingSheetView(
                content: content,
                coordinator: state.coordinator
            )
        }
    }

    var body: some View {
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: presentedContent.preferredColorScheme(.light)
            case .dark: presentedContent.preferredColorScheme(.dark)
            case .system: presentedContent
            }
        }
    }
}

private extension OnboardingWindowPresenter {
    func teardownObservers() {
        if let o = distributedObserver { DistributedNotificationCenter.default().removeObserver(o) }
        distributedObserver = nil
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        defaultsObserver = nil
    }

    func makeRootView() -> AnyView {
        guard let state else { return AnyView(EmptyView()) }
        return AnyView(OnboardingWindowRoot(state: state))
    }

    func handleEffectiveAppearanceChange() {
        guard window != nil, hostingView != nil else { return }
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        guard appAppearance == .system else { return }
        applyAppearance(forceRedraw: true)
    }

    func handleAppearancePreferenceChange() {
        guard window != nil, hostingView != nil else { return }
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        guard raw != lastAppAppearanceRaw else { return }
        lastAppAppearanceRaw = raw
        applyAppearance(forceRedraw: true)
    }

    func applyAppearance(forceRedraw: Bool) {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        switch appAppearance {
        case .system:
            window?.appearance = nil
        case .light:
            window?.appearance = NSAppearance(named: .aqua)
        case .dark:
            window?.appearance = NSAppearance(named: .darkAqua)
        }
        guard forceRedraw, let hv = hostingView else { return }
        hv.needsLayout = true
        hv.setNeedsDisplay(hv.bounds)
        hv.displayIfNeeded()
    }
}
