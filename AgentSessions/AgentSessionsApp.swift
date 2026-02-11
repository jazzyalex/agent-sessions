import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let openSessionsSearchFromMenu = Notification.Name("AgentSessionsOpenSessionsSearchFromMenu")
    static let openTranscriptFindFromMenu = Notification.Name("AgentSessionsOpenTranscriptFindFromMenu")
    static let showOnboardingFromMenu = Notification.Name("AgentSessionsShowOnboardingFromMenu")
    static let navigateToSessionFromImages = Notification.Name("AgentSessionsNavigateToSessionFromImages")
    static let navigateToSessionEventFromImages = Notification.Name("AgentSessionsNavigateToSessionEventFromImages")
    static let showImagesFromMenu = Notification.Name("AgentSessionsShowImagesFromMenu")
    static let showImagesForInlineImage = Notification.Name("AgentSessionsShowImagesForInlineImage")
    static let selectImagesBrowserItem = Notification.Name("AgentSessionsSelectImagesBrowserItem")
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
    @StateObject private var openclawIndexer = OpenClawSessionIndexer()
    @StateObject private var updaterController = UpdaterController()
    @StateObject private var onboardingCoordinator = OnboardingCoordinator()
    @StateObject private var unifiedIndexerHolder = _UnifiedHolder()
    @State private var statusItemController: StatusItemController? = nil
    @State private var analyticsToggleObserver: NSObjectProtocol?
    @State private var mainWindowCloseObserver: NSObjectProtocol?
    @State private var didRunStartupTasks: Bool = false
    private let onboardingWindowPresenter = OnboardingWindowPresenter()
    @AppStorage("MenuBarEnabled") private var menuBarEnabled: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("LayoutMode") private var layoutModeRaw: String = LayoutMode.vertical.rawValue
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
                droidIndexer: droidIndexer,
                openclawIndexer: openclawIndexer
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
                openclawIndexer: openclawIndexer,
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
                    if UpdaterController.shared == nil || UpdaterController.shared !== updaterController {
                        UpdaterController.shared = updaterController
                    }
                    setupMainWindowCloseObserverIfNeeded()

                    if !didRunStartupTasks {
                        didRunStartupTasks = true
                        LaunchProfiler.reset("Unified main window")
                        LaunchProfiler.log("Window appeared")
                        LaunchProfiler.log("UnifiedSessionIndexer.refresh() invoked")
                        Task {
                            let detectedCount = await CrashReportingService.shared.detectAndQueueOnLaunch()
                            if detectedCount > 0 {
                                await presentCrashRecoveryPrompt(newCrashCount: detectedCount)
                            }
                        }
                        onboardingCoordinator.checkAndPresentIfNeeded()
                        unifiedIndexerHolder.unified?.refresh()
                        setupAnalytics()
                    }

                    let isAppActive = NSApp?.isActive ?? true
                    unifiedIndexerHolder.unified?.setAppActive(isAppActive)
                    codexUsageModel.setAppActive(isAppActive)
                    claudeUsageModel.setAppActive(isAppActive)
                    updateUsageModels()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    unifiedIndexerHolder.unified?.setAppActive(true)
                    codexUsageModel.setAppActive(true)
                    claudeUsageModel.setAppActive(true)
                    archiveManager.syncPinnedSessionsNow()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    unifiedIndexerHolder.unified?.setAppActive(false)
                    codexUsageModel.setAppActive(false)
                    claudeUsageModel.setAppActive(false)
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
                .onChange(of: onboardingCoordinator.isPresented) { _, isPresented in
                    if isPresented, let content = onboardingCoordinator.content {
                        onboardingWindowPresenter.show(
                            content: content,
                            coordinator: onboardingCoordinator,
                            codexIndexer: indexer,
                            claudeIndexer: claudeIndexer,
                            geminiIndexer: geminiIndexer,
                            opencodeIndexer: opencodeIndexer,
                            copilotIndexer: copilotIndexer,
                            droidIndexer: droidIndexer,
                            openclawIndexer: openclawIndexer,
                            codexUsageModel: codexUsageModel,
                            claudeUsageModel: claudeUsageModel
                        )
                    } else {
                        onboardingWindowPresenter.hide()
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

                Button("Find in Transcript…") {
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
                Button("Image Browser") {
                    NotificationCenter.default.post(name: .showImagesFromMenu, object: nil)
                }
                OpenPinnedSessionsWindowButton()
            }
            CommandGroup(after: .help) {
                Button("Show Onboarding") {
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
                    droidIndexer: droidIndexer,
                    openclawIndexer: openclawIndexer
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
                     droidIndexer: DroidSessionIndexer,
                     openclawIndexer: OpenClawSessionIndexer) -> UnifiedSessionIndexer {
        if let u = unified { return u }
        let u = UnifiedSessionIndexer(codexIndexer: codexIndexer,
                                      claudeIndexer: claudeIndexer,
                                      geminiIndexer: geminiIndexer,
                                      opencodeIndexer: opencodeIndexer,
                                      copilotIndexer: copilotIndexer,
                                      droidIndexer: droidIndexer,
                                      openclawIndexer: openclawIndexer)
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
        Button("Saved Sessions") {
            openWindow(id: "PinnedSessions")
        }
        .keyboardShortcut("p", modifiers: [.command, .option, .shift])
    }
}

extension AgentSessionsApp {
    private static let mainUnifiedWindowTitle = "Agent Sessions"

    private static let crashSupportRecipient = "jazzyalex@gmail.com"
    private static let crashIssueURL = URL(string: "https://github.com/jazzyalex/agent-sessions/issues/new?title=Crash%20Report&body=Please%20attach%20the%20exported%20crash%20report%20JSON%20file%20and%20steps%20to%20reproduce.")!

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

        let anyUsageTrackingEnabled = codexTrackingEnabled || claudeTrackingEnabled
        statusItemController?.setEnabled(menuBarEnabled && anyUsageTrackingEnabled)
    }

    private func setupAnalytics() {
        if AppRuntime.isRunningTests { return }
        guard analyticsService == nil else { return }
        if let observer = analyticsToggleObserver {
            NotificationCenter.default.removeObserver(observer)
            analyticsToggleObserver = nil
        }

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
        analyticsToggleObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ToggleAnalyticsWindow"),
            object: nil,
            queue: .main
        ) { [weak service, weak controller] _ in
            Task { @MainActor in
                guard let service, let controller else { return }
                guard service.isReady else {
                    NSSound.beep()
                    print("[Analytics] Ignoring toggle – analytics still warming up")
                    return
                }
                controller.toggle()
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
        content: OnboardingContent,
        coordinator: OnboardingCoordinator,
        codexIndexer: SessionIndexer,
        claudeIndexer: ClaudeSessionIndexer,
        geminiIndexer: GeminiSessionIndexer,
        opencodeIndexer: OpenCodeSessionIndexer,
        copilotIndexer: CopilotSessionIndexer,
        droidIndexer: DroidSessionIndexer,
        openclawIndexer: OpenClawSessionIndexer,
        codexUsageModel: CodexUsageModel,
        claudeUsageModel: ClaudeUsageModel
    ) {
        self.coordinator = coordinator
        state = OnboardingWindowState(
            content: content,
            coordinator: coordinator,
            codexIndexer: codexIndexer,
            claudeIndexer: claudeIndexer,
            geminiIndexer: geminiIndexer,
            opencodeIndexer: opencodeIndexer,
            copilotIndexer: copilotIndexer,
            droidIndexer: droidIndexer,
            openclawIndexer: openclawIndexer,
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
        if coordinator?.isPresented == true {
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
    let content: OnboardingContent
    let coordinator: OnboardingCoordinator
    let codexIndexer: SessionIndexer
    let claudeIndexer: ClaudeSessionIndexer
    let geminiIndexer: GeminiSessionIndexer
    let opencodeIndexer: OpenCodeSessionIndexer
    let copilotIndexer: CopilotSessionIndexer
    let droidIndexer: DroidSessionIndexer
    let openclawIndexer: OpenClawSessionIndexer
    let codexUsageModel: CodexUsageModel
    let claudeUsageModel: ClaudeUsageModel
}

private struct OnboardingWindowRoot: View {
    let state: OnboardingWindowState
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        let content = OnboardingSheetView(
            content: state.content,
            coordinator: state.coordinator,
            codexIndexer: state.codexIndexer,
            claudeIndexer: state.claudeIndexer,
            geminiIndexer: state.geminiIndexer,
            opencodeIndexer: state.opencodeIndexer,
            copilotIndexer: state.copilotIndexer,
            droidIndexer: state.droidIndexer,
            openclawIndexer: state.openclawIndexer,
            codexUsageModel: state.codexUsageModel,
            claudeUsageModel: state.claudeUsageModel
        )

        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark: content.preferredColorScheme(.dark)
            case .system: content
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
