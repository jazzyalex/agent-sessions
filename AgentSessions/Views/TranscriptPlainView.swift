import SwiftUI
import AppKit
import Foundation

private enum TranscriptToolbarStyle {
    static let baseFont = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let compactFont = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let popoverFont = Font.system(size: 12, weight: .medium, design: .monospaced)
}

/// Codex transcript view - now a wrapper around UnifiedTranscriptView
struct TranscriptPlainView: View {
    @EnvironmentObject var indexer: SessionIndexer
    let sessionID: String?

    var body: some View {
        UnifiedTranscriptView(
            indexer: indexer,
            sessionID: sessionID,
            sessionIDExtractor: codexSessionID,
            sessionIDLabel: "Codex",
            enableCaching: true
        )
    }

    private func codexSessionID(for session: Session) -> String? {
        // Extract full Codex session ID (base64 or UUID from filepath)
        let base = URL(fileURLWithPath: session.filePath).deletingPathExtension().lastPathComponent
        if base.count >= 8 { return base }
        return nil
    }
}

/// Unified transcript view that works with both Codex and Claude session indexers
struct UnifiedTranscriptView<Indexer: SessionIndexerProtocol>: View {
    @ObservedObject var indexer: Indexer
    @EnvironmentObject var focusCoordinator: WindowFocusCoordinator
    @EnvironmentObject var archiveManager: SessionArchiveManager
    @Environment(\.colorScheme) private var colorScheme
    let sessionID: String?
    let sessionIDExtractor: (Session) -> String?  // Extract ID for clipboard
    let sessionIDLabel: String  // "Codex" or "Claude"
    let enableCaching: Bool  // Codex uses cache, Claude doesn't

    // Plain transcript buffer
    @State private var transcript: String = ""
    @State private var rebuildTask: Task<Void, Never>?

    // Find
    @State private var findText: String = ""
    @State private var findMatches: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = 0
    @FocusState private var findFocused: Bool
    @State private var allowFindFocus: Bool = false
    @State private var highlightRanges: [NSRange] = []
    @State private var commandRanges: [NSRange] = []
    @State private var userRanges: [NSRange] = []
    @State private var assistantRanges: [NSRange] = []
    @State private var outputRanges: [NSRange] = []
    @State private var errorRanges: [NSRange] = []
    @State private var hasCommands: Bool = false
    @State private var isBuildingJSON: Bool = false
    // Terminal-specific find state (used when viewMode == .terminal)
    @State private var terminalFindMatchesCount: Int = 0
    @State private var terminalFindCurrentIndex: Int = 0
    @State private var terminalFindToken: Int = 0
    @State private var terminalFindDirection: Int = 1
    @State private var terminalFindResetFlag: Bool = true

    // Toggles (view-scoped)
    @State private var showTimestamps: Bool = false
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.terminal.rawValue
    @AppStorage("SessionViewMode") private var viewModeRaw: String = SessionViewMode.terminal.rawValue
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false

    private var viewMode: SessionViewMode {
        // Prefer persisted view mode when valid; otherwise derive from legacy renderModeRaw.
        if let m = SessionViewMode(rawValue: viewModeRaw) {
            return m
        }
        let legacy = TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal
        return SessionViewMode.from(legacy)
    }

    /// Keep the legacy TranscriptRenderMode preference in sync with SessionViewMode
    /// so existing callers that read only renderModeRaw still behave correctly.
    private func syncRenderModeWithViewMode() {
        let mapped = viewMode.transcriptRenderMode.rawValue
        if renderModeRaw != mapped {
            renderModeRaw = mapped
        }
    }

    // Auto-colorize in Terminal mode
    private var shouldColorize: Bool {
        return viewMode == .terminal
    }

    private var isJSONMode: Bool {
        return viewMode == .json
    }

    // Raw sheet
    @State private var showRawSheet: Bool = false
    // Selection for auto-scroll to find matches
    @State private var selectedNSRange: NSRange? = nil
    @State private var selectionScrollMode: SelectionScrollMode = .ensureVisible
    // Ephemeral copy confirmation (popover)
    @State private var showIDCopiedPopover: Bool = false
    // Terminal-only jump trigger (Color view uses SessionTerminalView, not NSTextView selection)
    @State private var terminalJumpToken: Int = 0
    // Terminal-only role navigation trigger (User/Tools/Errors)
    @State private var terminalRoleNavToken: Int = 0
    @State private var terminalRoleNavRole: SessionTerminalView.RoleToggle = .user
    @State private var terminalRoleNavDirection: Int = 1

    // Plain view navigation cursors (used for keyboard jumps)
    @State private var lastUserJumpLocation: Int? = nil
    @State private var lastToolsJumpLocation: Int? = nil
    @State private var lastErrorJumpLocation: Int? = nil

    // Simple memoization (for Codex)
    @State private var transcriptCache: [String: String] = [:]
    @State private var terminalCommandRangesCache: [String: [NSRange]] = [:]
    @State private var terminalUserRangesCache: [String: [NSRange]] = [:]
    @State private var lastBuildKey: String? = nil

    private var shouldShowLoadingAnimation: Bool {
        guard let id = sessionID else { return false }
        return indexer.isLoadingSession && indexer.loadingSessionID == id
    }

    var body: some View {
        if let id = sessionID, let session = indexer.allSessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                toolbar(session: session)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                Divider()
                ZStack {
                    if viewMode == .terminal {
                        SessionTerminalView(
                            session: session,
                            findQuery: findText,
                            findToken: terminalFindToken,
                            findDirection: terminalFindDirection,
                            findReset: terminalFindResetFlag,
                            jumpToken: terminalJumpToken,
                            roleNavToken: terminalRoleNavToken,
                            roleNavRole: terminalRoleNavRole,
                            roleNavDirection: terminalRoleNavDirection,
                            externalMatchCount: $terminalFindMatchesCount,
                            externalCurrentMatchIndex: $terminalFindCurrentIndex
                        )
                    } else {
                        PlainTextScrollView(
                            text: transcript,
                            selection: selectedNSRange,
                            selectionScrollMode: selectionScrollMode,
                            fontSize: CGFloat(transcriptFontSize),
                            highlights: highlightRanges,
                            currentIndex: currentMatchIndex,
                            commandRanges: (shouldColorize || isJSONMode) ? commandRanges : [],
                            userRanges: (shouldColorize || isJSONMode) ? userRanges : [],
                            assistantRanges: (shouldColorize || isJSONMode) ? assistantRanges : [],
                            outputRanges: (shouldColorize || isJSONMode) ? outputRanges : [],
                            errorRanges: (shouldColorize || isJSONMode) ? errorRanges : [],
                            isJSONMode: isJSONMode,
                            appAppearanceRaw: appAppearanceRaw,
                            colorScheme: colorScheme,
                            monochrome: stripMonochrome
                        )
                    }

                    // Show animation during lazy load OR full refresh
                    if shouldShowLoadingAnimation {
                        LoadingAnimationView(
                            codexColor: Color.agentCodex,
                            claudeColor: Color.agentClaude
                        )
                    }
                }
            }
            .onAppear { rebuild(session: session) }
            .onChange(of: id) { _, _ in rebuild(session: session) }
            .onChange(of: viewModeRaw) { _, _ in
                syncRenderModeWithViewMode()
                rebuild(session: session)
            }
            .onChange(of: session.events.count) { _, _ in rebuild(session: session) }
            .onChange(of: findFocused) { _, newValue in
                #if DEBUG
                print("🔍 FIND FOCUSED CHANGED: \(newValue) (allowFindFocus=\(allowFindFocus))")
                #endif
            }
            .onChange(of: allowFindFocus) { _, newValue in
                #if DEBUG
                print("🔓 ALLOW FIND FOCUS CHANGED: \(newValue)")
                #endif
            }
            .onChange(of: focusCoordinator.activeFocus) { oldFocus, newFocus in
                #if DEBUG
                print("🎯 COORDINATOR FOCUS CHANGE: \(oldFocus) → \(newFocus)")
                #endif
                if newFocus == .transcriptFind {
                    #if DEBUG
                    print("  ↳ Setting allowFindFocus=true, findFocused=true")
                    #endif
                    allowFindFocus = true
                    findFocused = true
                } else if oldFocus == .transcriptFind {
                    #if DEBUG
                    print("  ↳ Leaving transcriptFind: findFocused=false, allowFindFocus=false")
                    #endif
                    findFocused = false
                    allowFindFocus = false
                } else if newFocus != .transcriptFind && newFocus != .none {
                    #if DEBUG
                    print("  ↳ Setting findFocused=false, allowFindFocus=false")
                    #endif
                    // Another search UI became active - release focus
                    findFocused = false
                    allowFindFocus = false
                } else {
                    #if DEBUG
                    print("  ↳ NO ACTION (newFocus=\(newFocus))")
                    #endif
                }
            }
            .sheet(isPresented: $showRawSheet) { WholeSessionRawPrettySheet(session: session) }
            .onChange(of: indexer.requestOpenRawSheet) { _, newVal in
                if newVal {
                    showRawSheet = true
                    indexer.requestOpenRawSheet = false
                }
            }
        } else {
            Text("Select a session to view transcript")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toolbar(session: Session) -> some View {
        HStack(spacing: 0) {
            // Invisible button to capture Cmd+F shortcut
            Button(action: { focusCoordinator.perform(.openTranscriptFind) }) { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .focusable(false)
                .hidden()

            // Invisible button to toggle Plain/Color with Cmd+Shift+T
            Button(action: {
                let current = SessionViewMode.from(TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal)
                let next: SessionViewMode
                switch current {
                case .transcript:
                    next = .terminal
                case .terminal:
                    next = .transcript
                case .json:
                    // From JSON, Cmd+Shift+T toggles back to Plain.
                    next = .transcript
                }
                viewModeRaw = next.rawValue
                renderModeRaw = next.transcriptRenderMode.rawValue
            }) { EmptyView() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .focusable(false)
                .hidden()

            // Invisible buttons to capture arrow-based transcript navigation shortcuts.
            Button(action: { jumpUser(direction: 1) }) { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .focusable(false)
                .hidden()
            Button(action: { jumpUser(direction: -1) }) { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .focusable(false)
                .hidden()
            Button(action: { jumpTools(direction: 1) }) { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .focusable(false)
                .hidden()
            Button(action: { jumpTools(direction: -1) }) { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .focusable(false)
                .hidden()
            Button(action: { jumpErrors(direction: 1) }) { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
                .focusable(false)
                .hidden()
            Button(action: { jumpErrors(direction: -1) }) { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
                .focusable(false)
                .hidden()

            // === LEADING GROUP: View Mode Segmented Control + JSON status + ID ===
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                Picker("View Style", selection: $viewModeRaw) {
                    Text("Plain")
                        .tag(SessionViewMode.transcript.rawValue)
                        .help("Plain view \u{2014} merged chat and tools. Cmd+Shift+T toggles between Plain and Color.")
                    Text("Color")
                            .tag(SessionViewMode.terminal.rawValue)
                            .help("Color view \u{2014} terminal-inspired output with colorized commands and tool output. Cmd+Shift+T toggles between Plain and Color.")
                        Text("JSON")
                            .tag(SessionViewMode.json.rawValue)
                            .help("JSON view \u{2014} formatted session JSON for readability. Encrypted blobs and large text blocks are summarized; use the session file on disk for raw JSON.")
                }
                .pickerStyle(.segmented)
                .font(TranscriptToolbarStyle.baseFont)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 200)
                .accessibilityLabel("View Style")

                    if isJSONMode && isBuildingJSON {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text("Building JSON view…")
                    }
                    .font(TranscriptToolbarStyle.compactFont)
                    .foregroundStyle(.secondary)
                }
            }

                HStack(spacing: 10) {
                    if let fullID = sessionIDExtractor(session) {
                        let displayLast4 = String(fullID.suffix(4))
                        let short = extractShortID(for: session) ?? String(fullID.prefix(6))
                        Button(action: { copySessionID(for: session) }) {
                            HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .imageScale(.medium)
                            Text("ID \(displayLast4)")
                                .font(TranscriptToolbarStyle.baseFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Copy session ID: \(short) (⌘⇧C)")
                        .accessibilityLabel("Copy Session ID")
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .popover(isPresented: $showIDCopiedPopover, arrowEdge: .bottom) {
                        Text("ID Copied!")
                            .padding(8)
                            .font(TranscriptToolbarStyle.popoverFont)
                    }
                }
                if StarredSessionsStore().contains(id: session.id, source: session.source) {
                    pinnedBadge(session: session)
                    }
                }
            }
            .padding(.leading, 12)

            Spacer(minLength: 12)

            // MID: Text size controls (moved next to ID)
            HStack(spacing: 6) {
                Button(action: { adjustFont(-1) }) {
                    HStack(spacing: 2) {
                        Text("A").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text("−").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("-", modifiers: .command)
                .help("Decrease text size (⌘−)")
                .accessibilityLabel("Decrease Text Size")

                Button(action: { adjustFont(1) }) {
                    HStack(spacing: 2) {
                        Text("A").font(.system(size: 14, weight: .semibold, design: .monospaced))
                        Text("+").font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("+", modifiers: .command)
                .help("Increase text size (⌘+)")
                .accessibilityLabel("Increase Text Size")
            }

            Spacer()

            // === TRAILING GROUP: Copy and Find Controls ===
            HStack(spacing: 12) {
                // Copy transcript button
                Button("Copy") { copyAll() }
                    .buttonStyle(.borderless)
                    .font(TranscriptToolbarStyle.baseFont)
                    .help("Copy entire transcript to clipboard (⌥⌘C)")
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .accessibilityLabel("Copy Transcript")

                Divider().frame(height: 20)

                // Find Controls (HIG-compliant placement)
                HStack(spacing: 6) {
                // Find search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                    TextField("Find", text: $findText)
                        .textFieldStyle(.plain)
                        .font(TranscriptToolbarStyle.baseFont)
                        .focused($findFocused)
                        .focusable(allowFindFocus)
                        .onChange(of: findText) { oldValue, newValue in
                            // If the user clears the field via typing/backspace (not the clear button),
                            // ensure we immediately remove any painted highlights.
                            if !oldValue.isEmpty, newValue.isEmpty {
                                performFind(resetIndex: true)
                            }
                        }
                        .onSubmit { performFind(resetIndex: true) }
                        .accessibilityLabel("Find in transcript")
                        .frame(minWidth: 120, idealWidth: 220, maxWidth: 360)
                    if findText.isEmpty {
                        Text("⌘F")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if !findText.isEmpty {
                        Button(action: { findText = ""; performFind(resetIndex: true) }) {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("Clear search (⎋)")
                        .keyboardShortcut(.escape)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(findFocused ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.25), lineWidth: findFocused ? 2 : 1)
                )
                .onTapGesture { focusCoordinator.perform(.openTranscriptFind) }

                // Next/Previous controls group
                HStack(spacing: 2) {
                    Button(action: { performFind(resetIndex: false, direction: -1) }) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(isFindNavigationDisabled)
                    .help("Previous match (⇧⌘G)")
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Button(action: { performFind(resetIndex: false, direction: 1) }) {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(isFindNavigationDisabled)
                    .help("Next match (⌘G)")
                    .keyboardShortcut("g", modifiers: .command)
                }
                
                // Match count badge
                if !findText.isEmpty {
                    Text(findStatus())
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isFindNavigationDisabled ? .red : .secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                        .accessibilityLabel("\(currentMatchIndex + 1) of \(findMatches.count) matches")
                }
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func rebuild(session: Session) {
        rebuildTask?.cancel()
        rebuildTask = nil

        syncRenderModeWithViewMode()
        let filters: TranscriptFilters = .current(showTimestamps: showTimestamps, showMeta: false)
        let mode = viewMode.transcriptRenderMode
        let skipFlag = skipAgentsPreambleEnabled() ? 1 : 0
        let buildKey = "\(session.id)|\(session.events.count)|\(viewMode.rawValue)|\(showTimestamps ? 1 : 0)|\(skipFlag)"

        #if DEBUG
        print("🔨 REBUILD: mode=\(mode) shouldColorize=\(shouldColorize) enableCaching=\(enableCaching)")
        #endif

        if enableCaching {
            // Memoization key: session identity, event count, render mode, and timestamp setting
            let key = buildKey
            if lastBuildKey == key { return }
            // Try in-view memo cache first
            if let cached = transcriptCache[key] {
                transcript = decorateTranscriptIfNeeded(cached, session: session)
                if viewMode == .json {
                    let hasToolCommands = session.events.contains { $0.kind == .tool_call }
                    scheduleJSONBuild(session: session, key: key, shouldCache: true, hasCommands: hasToolCommands, cachedText: cached)
                    return
                }
                if viewMode == .terminal && shouldColorize {
                    commandRanges = terminalCommandRangesCache[key] ?? []
                    userRanges = terminalUserRangesCache[key] ?? []
                    hasCommands = !(commandRanges.isEmpty)
                    findAdditionalRanges()
                } else {
                    commandRanges = []; userRanges = []; assistantRanges = []; outputRanges = []; errorRanges = []
                    hasCommands = session.events.contains { $0.kind == .tool_call }
                    computeNavigationRangesIfNeeded()
                }
                lastBuildKey = key
                // Reset find state
                performFind(resetIndex: true)
                selectedNSRange = nil
                resetJumpCursors()
                updateSelectionToCurrentMatch()
                maybeAutoJumpToFirstPrompt(session: session)
                return
            }

            // JSON mode: build pretty-printed JSON once and cache it; skip indexer caches.
            if viewMode == .json {
                let hasToolCommands = session.events.contains { $0.kind == .tool_call }
                scheduleJSONBuild(session: session, key: key, shouldCache: true, hasCommands: hasToolCommands)
                return
            }

            // Try external indexer transcript caches (Codex/Claude/Gemini) without generation
            if FeatureFlags.offloadTranscriptBuildInView {
                if let t = externalCachedTranscript(for: session.id) {
                    let decorated = decorateTranscriptIfNeeded(t, session: session)
                    transcript = decorated
                    commandRanges = []; userRanges = []; assistantRanges = []; outputRanges = []; errorRanges = []
                    hasCommands = session.events.contains { $0.kind == .tool_call }
                    computeNavigationRangesIfNeeded()
                    transcriptCache[key] = decorated
                    lastBuildKey = key
                    performFind(resetIndex: true)
                    selectedNSRange = nil
                    resetJumpCursors()
                    updateSelectionToCurrentMatch()
                    maybeAutoJumpToFirstPrompt(session: session)
                    return
                }

                // Build off-main to avoid UI stalls
                let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
                let shouldColorize = self.shouldColorize
                Task.detached(priority: prio) {
                    let sessionHasCommands = session.events.contains { $0.kind == .tool_call }
                    if mode == .terminal && shouldColorize && sessionHasCommands {
                        let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
                        await MainActor.run {
                            let decorated = self.decorateTranscriptIfNeeded(built.0, session: session)
                            self.transcript = decorated
                            self.commandRanges = built.1
                            self.userRanges = built.2
                            self.assistantRanges = []
                            self.outputRanges = []
                            self.errorRanges = []
                            self.hasCommands = true
                            self.findAdditionalRanges()
                            self.transcriptCache[key] = decorated
                            self.terminalCommandRangesCache[key] = built.1
                            self.terminalUserRangesCache[key] = built.2
                            self.lastBuildKey = key
                            self.performFind(resetIndex: true)
                            self.selectedNSRange = nil
                            self.updateSelectionToCurrentMatch()
                            self.maybeAutoJumpToFirstPrompt(session: session)
                        }
                    } else {
                        let t = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: .normal)
                        await MainActor.run {
                            let decorated = self.decorateTranscriptIfNeeded(t, session: session)
                            self.transcript = decorated
                            self.commandRanges = []
                            self.userRanges = []
                            self.assistantRanges = []
                            self.outputRanges = []
                            self.errorRanges = []
                            self.hasCommands = sessionHasCommands
                            self.computeNavigationRangesIfNeeded()
                            self.transcriptCache[key] = decorated
                            self.lastBuildKey = key
                            self.performFind(resetIndex: true)
                            self.selectedNSRange = nil
                            self.resetJumpCursors()
                            self.updateSelectionToCurrentMatch()
                            self.maybeAutoJumpToFirstPrompt(session: session)
                        }
                    }
                }
                return
            }

            // Fallback: synchronous build (legacy behavior)
            let sessionHasCommands = session.events.contains { $0.kind == .tool_call }
            if mode == .terminal && shouldColorize && sessionHasCommands {
                let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
                transcript = decorateTranscriptIfNeeded(built.0, session: session)
                commandRanges = built.1
                userRanges = built.2
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                findAdditionalRanges()
                transcriptCache[key] = transcript
                terminalCommandRangesCache[key] = commandRanges
                terminalUserRangesCache[key] = userRanges
                lastBuildKey = key
            } else {
                transcript = decorateTranscriptIfNeeded(SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: .normal), session: session)
                commandRanges = []
                userRanges = []
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                computeNavigationRangesIfNeeded()
                transcriptCache[key] = transcript
                lastBuildKey = key
            }
        } else {
            // No caching (Claude)
            let sessionHasCommands2 = session.events.contains { $0.kind == .tool_call }
            if viewMode == .json {
                scheduleJSONBuild(session: session, key: buildKey, shouldCache: false, hasCommands: sessionHasCommands2)
                return
            }

            // Build off-main to avoid UI stalls on heavy sessions (e.g., Chrome MCP screenshots).
            let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
            let shouldColorizeSnapshot = shouldColorize
            let modeSnapshot = mode
            let keySnapshot = buildKey
            let sessionSnapshot = session
            rebuildTask = Task.detached(priority: prio) {
                if modeSnapshot == .terminal && shouldColorizeSnapshot && sessionHasCommands2 {
                    let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: sessionSnapshot, filters: filters)
                    await MainActor.run {
                        guard self.sessionID == sessionSnapshot.id else { return }
                        guard !Task.isCancelled else { return }
                        let decorated = self.decorateTranscriptIfNeeded(built.0, session: sessionSnapshot)
                        self.transcript = decorated
                        // In terminal mode, the UI uses SessionTerminalView; keep these empty to avoid extra scans.
                        self.commandRanges = []
                        self.userRanges = []
                        self.assistantRanges = []
                        self.outputRanges = []
                        self.errorRanges = []
                        self.hasCommands = true
                        self.lastBuildKey = keySnapshot
                        self.performFind(resetIndex: true)
                        self.selectedNSRange = nil
                        self.resetJumpCursors()
                        self.updateSelectionToCurrentMatch()
                        self.maybeAutoJumpToFirstPrompt(session: sessionSnapshot)
                    }
                } else {
                    let t = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: sessionSnapshot, filters: filters, mode: .normal)
                    await MainActor.run {
                        guard self.sessionID == sessionSnapshot.id else { return }
                        guard !Task.isCancelled else { return }
                        let decorated = self.decorateTranscriptIfNeeded(t, session: sessionSnapshot)
                        self.transcript = decorated
                        self.commandRanges = []
                        self.userRanges = []
                        self.assistantRanges = []
                        self.outputRanges = []
                        self.errorRanges = []
                        self.hasCommands = sessionHasCommands2
                        if self.viewMode != .terminal && self.viewMode != .json {
                            self.computeNavigationRangesIfNeeded()
                        }
                        self.lastBuildKey = keySnapshot
                        self.performFind(resetIndex: true)
                        self.selectedNSRange = nil
                        self.resetJumpCursors()
                        self.updateSelectionToCurrentMatch()
                        self.maybeAutoJumpToFirstPrompt(session: sessionSnapshot)
                    }
                }
            }
            return
        }

        // Reset find state
        performFind(resetIndex: true)
        selectedNSRange = nil
        resetJumpCursors()
        updateSelectionToCurrentMatch()
        maybeAutoJumpToFirstPrompt(session: session)
    }

    private func externalCachedTranscript(for id: String) -> String? {
        // Attempt to read from indexer-level caches (non-generating)
        if let codex = indexer as? SessionIndexer {
            return codex.searchTranscriptCache.getCached(id)
        } else if let claude = indexer as? ClaudeSessionIndexer {
            return claude.searchTranscriptCache.getCached(id)
        } else if let gemini = indexer as? GeminiSessionIndexer {
            return gemini.searchTranscriptCache.getCached(id)
        }
        return nil
    }

	    private func performFind(resetIndex: Bool, direction: Int = 1) {
	        // Terminal mode uses a dedicated line-based search in SessionTerminalView.
	        if viewMode == .terminal {
	            let q = findText
	            guard !q.isEmpty else {
	                terminalFindMatchesCount = 0
	                terminalFindCurrentIndex = 0
	                terminalFindToken &+= 1
	                selectedNSRange = nil
	                return
	            }
	            terminalFindDirection = direction
	            terminalFindResetFlag = resetIndex
	            terminalFindToken &+= 1
	            return
        }

	        let q = findText
	        guard !q.isEmpty else {
	            findMatches = []
	            currentMatchIndex = 0
	            highlightRanges = []
	            selectedNSRange = nil
	            return
	        }
        // Find matches directly on the original string using case-insensitive search
        var matches: [Range<String.Index>] = []
        var searchStart = transcript.startIndex
        while let r = transcript.range(of: q, options: [.caseInsensitive], range: searchStart..<transcript.endIndex) {
            matches.append(r)
            searchStart = r.upperBound
        }
        findMatches = matches
        if matches.isEmpty {
            currentMatchIndex = 0
            highlightRanges = []
        } else {
            if resetIndex {
                currentMatchIndex = 0
            } else {
                var newIdx = currentMatchIndex + direction
                if newIdx < 0 { newIdx = matches.count - 1 }
                if newIdx >= matches.count { newIdx = 0 }
                currentMatchIndex = newIdx
            }

            // Convert to NSRange and validate bounds
            let transcriptLength = (transcript as NSString).length
            let validRanges = matches.compactMap { range -> NSRange? in
                let nsRange = NSRange(range, in: transcript)
                // Validate bounds
                if NSMaxRange(nsRange) <= transcriptLength {
                    return nsRange
                } else {
                    print("⚠️ FIND: Skipping out-of-bounds range \(nsRange) (transcript length: \(transcriptLength))")
                    return nil
                }
            }

            // Diagnostic logging for problematic sessions
            if validRanges.count != matches.count {
                print("⚠️ FIND: Filtered \(matches.count - validRanges.count) out-of-bounds ranges (query: '\(q)', transcript: \(transcriptLength) chars)")
            }

            highlightRanges = validRanges

            // Adjust currentMatchIndex if out of bounds after filtering
            if highlightRanges.isEmpty {
                currentMatchIndex = 0
            } else if currentMatchIndex >= highlightRanges.count {
                currentMatchIndex = highlightRanges.count - 1
            }

            updateSelectionToCurrentMatch()
        }
    }

    private func updateSelectionToCurrentMatch() {
        guard !highlightRanges.isEmpty, currentMatchIndex < highlightRanges.count else {
            selectedNSRange = nil
            return
        }
        // Use selection only for scrolling, will be cleared immediately to avoid blue highlight
        selectionScrollMode = .ensureVisible
        selectedNSRange = highlightRanges[currentMatchIndex]
    }

    private func findStatus() -> String {
        if findText.isEmpty { return "" }
        if viewMode == .terminal {
            if terminalFindMatchesCount == 0 { return "0/0" }
            return "\(terminalFindCurrentIndex + 1)/\(terminalFindMatchesCount)"
        }
        if findMatches.isEmpty { return "0/0" }
        return "\(currentMatchIndex + 1)/\(findMatches.count)"
    }

    private var isFindNavigationDisabled: Bool {
        if viewMode == .terminal {
            return terminalFindMatchesCount == 0 || findText.isEmpty
        }
        return findMatches.isEmpty
    }

    private func adjustFont(_ delta: Int) {
        let newSize = transcriptFontSize + Double(delta)
        transcriptFontSize = max(8, min(32, newSize))
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func extractShortID(for session: Session) -> String? {
        if let full = sessionIDExtractor(session) {
            return String(full.prefix(6))
        }
        return nil
    }

    private func copySessionID(for session: Session) {
        guard let id = sessionIDExtractor(session) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        showIDCopiedPopover = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showIDCopiedPopover = false }
    }

    // Terminal mode additional colorization
    private func findAdditionalRanges() {
        let text = transcript
        var asst: [NSRange] = []
        var out: [NSRange] = []
        var err: [NSRange] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var pos = 0
        for line in lines {
            let len = line.utf16.count
            let lineStr = String(line)
            // Assistant markers: prefer ASCII, fall back to legacy glyph variant
            if lineStr.hasPrefix("[assistant] ") || lineStr.hasPrefix("assistant ∎ ") {
                let r = NSRange(location: pos, length: len)
                asst.append(r)
            // Output markers: prefer ASCII, also match legacy glyph and pipe-prefixed blocks
            } else if lineStr.hasPrefix("[out] ") || lineStr.hasPrefix("output ≡ ") || lineStr.hasPrefix("  | ") || lineStr.hasPrefix("⟪out⟫ ") {
                let r = NSRange(location: pos, length: len)
                out.append(r)
            // Error markers: prefer ASCII, fall back to legacy glyph variant
            } else if lineStr.hasPrefix("[error] ") || lineStr.hasPrefix("error ⚠ ") || lineStr.hasPrefix("! error ") {
                let r = NSRange(location: pos, length: len)
                err.append(r)
            }
            pos += len + 1
        }
        assistantRanges = asst
        outputRanges = out
        errorRanges = err
    }

    private func resetJumpCursors() {
        lastUserJumpLocation = nil
        lastToolsJumpLocation = nil
        lastErrorJumpLocation = nil
    }

    private func computeNavigationRangesIfNeeded() {
        guard viewMode != .terminal else { return }
        guard viewMode != .json else { return }

        // Build navigable ranges by scanning the transcript's stable prefixes. These ranges
        // are used for keyboard navigation, not styling (Plain view does not colorize).
        let text = transcript
        var users: [NSRange] = []
        var tools: [NSRange] = []
        var outs: [NSRange] = []
        var errs: [NSRange] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var pos = 0
        for line in lines {
            let len = line.utf16.count
            let range = NSRange(location: pos, length: max(1, len))

            let stripped = stripTimestampPrefixIfPresent(line)
            if stripped.hasPrefix(SessionTranscriptBuilder.userPrefix) {
                users.append(range)
            } else if stripped.hasPrefix(SessionTranscriptBuilder.toolPrefix) {
                tools.append(range)
            } else if stripped.hasPrefix(SessionTranscriptBuilder.outPrefix) {
                outs.append(range)
            } else if stripped.hasPrefix(SessionTranscriptBuilder.errorPrefix) {
                errs.append(range)
            }

            pos += len + 1
        }

        userRanges = users
        commandRanges = tools
        outputRanges = outs
        errorRanges = errs
    }

    private func stripTimestampPrefixIfPresent(_ line: Substring) -> Substring {
        guard showTimestamps else { return line }
        // Timestamp prefix uses a stable separator to avoid locale-dependent length assumptions.
        // Example: "1:23:45 PM • > Hello"
        let probe = line.prefix(40)
        guard let range = probe.range(of: AppDateFormatting.transcriptSeparator) else { return line }
        return line[range.upperBound...]
    }

    private enum JumpKind { case user, tools, errors }

    private func jumpUser(direction: Int) {
        // Some SwiftUI toolchains treat Shift as an "extra" modifier for arrow shortcuts.
        // If the user presses ⌥⌘⇧↑/↓, make sure it routes to Errors navigation.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            jumpErrors(direction: direction)
            return
        }
        if viewMode == .terminal {
            terminalRoleNavRole = .user
            terminalRoleNavDirection = direction
            terminalRoleNavToken &+= 1
            return
        }
        guard viewMode != .json else { return }
        jumpInPlain(kind: .user, direction: direction)
    }

    private func jumpTools(direction: Int) {
        if viewMode == .terminal {
            terminalRoleNavRole = .tools
            terminalRoleNavDirection = direction
            terminalRoleNavToken &+= 1
            return
        }
        guard viewMode != .json else { return }
        jumpInPlain(kind: .tools, direction: direction)
    }

    private func jumpErrors(direction: Int) {
        if viewMode == .terminal {
            terminalRoleNavRole = .errors
            terminalRoleNavDirection = direction
            terminalRoleNavToken &+= 1
            return
        }
        guard viewMode != .json else { return }
        jumpInPlain(kind: .errors, direction: direction)
    }

    private func jumpInPlain(kind: JumpKind, direction: Int) {
        computeNavigationRangesIfNeeded()

        let list: [NSRange] = {
            switch kind {
            case .user:
                return userRanges
            case .tools:
                return commandRanges + outputRanges
            case .errors:
                return errorRanges
            }
        }()

        let ranges = list
            .filter { $0.location >= 0 && $0.length > 0 }
            .sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { return }

        let cursor: Int? = {
            switch kind {
            case .user: return lastUserJumpLocation
            case .tools: return lastToolsJumpLocation
            case .errors: return lastErrorJumpLocation
            }
        }()

        let next: NSRange = {
            if direction >= 0 {
                let start = cursor ?? -1
                if let found = ranges.first(where: { $0.location > start }) { return found }
                return ranges.first!
            } else {
                let start = cursor ?? Int.max
                if let found = ranges.last(where: { $0.location < start }) { return found }
                return ranges.last!
            }
        }()

        switch kind {
        case .user: lastUserJumpLocation = next.location
        case .tools: lastToolsJumpLocation = next.location
        case .errors: lastErrorJumpLocation = next.location
        }

        selectionScrollMode = .alignTop
        selectedNSRange = next
    }

    private func firstConversationAnchor(in s: Session) -> String? {
        for ev in s.events.prefix(5000) {
            if ev.kind == .assistant, let t = ev.text, !t.isEmpty {
                let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count >= 10 {
                    return String(clean.prefix(60))
                }
            }
        }
        return nil
    }

    private func firstConversationRangeInTranscript(text: String) -> NSRange? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var pos = 0
        for line in lines {
            let len = line.utf16.count
            if String(line).hasPrefix("assistant ∎ ") {
                return NSRange(location: pos, length: len)
            }
            pos += len + 1
        }
        return nil
    }

    private func scheduleJSONBuild(session: Session, key: String, shouldCache: Bool, hasCommands: Bool, cachedText: String? = nil) {
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
        isBuildingJSON = true
        Task.detached(priority: prio) {
            let pretty = cachedText ?? prettyJSONForSession(session)
            let (keyRanges, stringRanges, numberRanges, keywordRanges) = jsonSyntaxHighlightRanges(for: pretty)
            await MainActor.run {
                self.transcript = pretty
                self.commandRanges = keyRanges
                self.userRanges = stringRanges
                self.assistantRanges = keywordRanges
                self.outputRanges = numberRanges
                self.errorRanges = []
                self.hasCommands = hasCommands
                if shouldCache {
                    self.transcriptCache[key] = pretty
                }
                self.lastBuildKey = key
                self.performFind(resetIndex: true)
                self.selectedNSRange = nil
                self.updateSelectionToCurrentMatch()
                self.isBuildingJSON = false
            }
        }
    }

    // MARK: - Agents.md preamble jump + divider (no trimming)

    private func skipAgentsPreambleEnabled() -> Bool {
        let d = UserDefaults.standard
        let key = PreferencesKey.Unified.skipAgentsPreamble
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    @ViewBuilder
    private func pinnedBadge(session: Session) -> some View {
        let info = archiveManager.info(source: session.source, id: session.id)
        let pinsEnabled = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        let statusText: String = {
            // Keep the badge lean: "Saved" is the only label; details live in the tooltip.
            if !pinsEnabled { return "Saved" }
            guard let info else { return "Saved" }
            if info.upstreamMissing { return "Saved" }
            switch info.status {
            case .none, .staging, .syncing, .final, .error:
                return "Saved"
            }
        }()

        Text(statusText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .help(pinnedHelpText(info: info))
    }

    private func pinnedHelpText(info: SessionArchiveInfo?) -> String {
        let pinsEnabled = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        guard pinsEnabled else { return "Saved session. Archiving is disabled in Settings." }
        guard let info else { return "Archive pending." }
        var parts: [String] = []
        if let last = info.lastSyncAt {
            let r = RelativeDateTimeFormatter()
            r.unitsStyle = .short
            parts.append("Last sync: \(r.localizedString(for: last, relativeTo: Date()))")
        } else {
            parts.append("Not yet synced")
        }
        if let bytes = info.archiveSizeBytes, bytes > 0 {
            parts.append("Archive size: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        }
        if info.upstreamMissing {
            parts.append("Upstream missing — archived copy only")
        }
        return parts.joined(separator: "\n")
    }

    private func shouldShowJumpToFirstPrompt(session: Session) -> Bool {
        guard skipAgentsPreambleEnabled() else { return false }
        if session.events.contains(where: { ($0.text?.contains("</INSTRUCTIONS>") ?? false) }) { return true }
        if session.source == .claude {
            let anchor = "caveat: the messages below were generated by the user while running local commands"
            return session.events.contains(where: { $0.kind == .user && ($0.text?.lowercased().contains(anchor) ?? false) })
        }
        if session.source == .droid {
            return session.events.contains(where: { $0.kind == .user && ($0.text.map { Session.isAgentsPreambleText($0) } ?? false) })
        }
        return false
    }

    private func jumpToFirstPrompt(session: Session) {
        if viewMode == .terminal {
            terminalJumpToken &+= 1
            return
        }
        let r: NSRange?
        if session.source == .codex {
            r = conversationStartRangeForJump(text: transcript)
        } else if session.source == .claude {
            r = claudeConversationStartRangeForJump(text: transcript, session: session)
        } else if session.source == .droid {
            r = droidConversationStartRangeForJump(text: transcript, session: session)
        } else {
            r = conversationStartRangeForJump(text: transcript)
        }
        guard let r else { return }
        selectionScrollMode = .alignTop
        selectedNSRange = r
    }

    private func maybeAutoJumpToFirstPrompt(session: Session) {
        guard skipAgentsPreambleEnabled() else { return }
        guard findText.isEmpty else { return }
        guard selectedNSRange == nil else { return }

        // Terminal view handles its own jump via SessionTerminalView.
        if viewMode == .terminal { return }

        if session.source == .codex, let r = conversationStartRangeForJump(text: transcript) {
            selectionScrollMode = .alignTop
            selectedNSRange = r
            return
        }

        if session.source == .claude, let r = claudeConversationStartRangeForJump(text: transcript, session: session) {
            selectionScrollMode = .alignTop
            selectedNSRange = r
            return
        }

        if session.source == .droid, let r = droidConversationStartRangeForJump(text: transcript, session: session) {
            selectionScrollMode = .alignTop
            selectedNSRange = r
            return
        }
    }

    private func droidConversationStartRangeForJump(text: String, session: Session) -> NSRange? {
        let hasPreamble = session.events.contains(where: { $0.kind == .user && ($0.text.map { Session.isAgentsPreambleText($0) } ?? false) })
        guard hasPreamble else { return nil }

        let divider = "──────── Conversation starts here"
        if let div = text.range(of: divider) {
            let start = div.lowerBound
            let end = text.index(after: start)
            return NSRange(start..<end, in: text)
        }
        return nil
    }

    private func claudeConversationStartRangeForJump(text: String, session: Session) -> NSRange? {
        // Only do Claude auto-jump when the local-command caveat preamble is present somewhere.
        let anchor = "caveat: the messages below were generated by the user while running local commands"
        let hasCaveat = session.events.contains(where: { $0.kind == .user && ($0.text?.lowercased().contains(anchor) ?? false) })
        guard hasCaveat else { return nil }

        // Prefer scrolling to the divider line itself so it lands as the top visible line.
        let divider = "──────── Conversation starts here"
        if let div = text.range(of: divider) {
            let start = div.lowerBound
            let end = text.index(after: start)
            return NSRange(start..<end, in: text)
        }

        for ev in session.events where ev.kind == .user {
            guard let raw = ev.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let lower = raw.lowercased()

            // If this is the caveat transcript block, try to jump to its extracted prompt tail.
            if lower.contains(anchor) {
                if let tail = Session.claudeLocalCommandPromptTail(from: raw),
                   let range = text.range(of: tail, options: []) {
                    // Jump to start-of-line to avoid leaving partial caveat text visible above.
                    var start = range.lowerBound
                    while start > text.startIndex {
                        let prev = text.index(before: start)
                        if text[prev] == "\n" { break }
                        start = prev
                    }
                    return NSRange(start..<text.index(after: start), in: text)
                }
                // Pure command transcript: skip this user event and continue to the next.
                continue
            }

            // Otherwise, jump to the first subsequent user prompt.
            if let range = text.range(of: raw, options: []) {
                var start = range.lowerBound
                while start > text.startIndex {
                    let prev = text.index(before: start)
                    if text[prev] == "\n" { break }
                    start = prev
                }
                return NSRange(start..<text.index(after: start), in: text)
            }
        }

        return nil
    }

    private func decorateTranscriptIfNeeded(_ raw: String, session: Session) -> String {
        guard skipAgentsPreambleEnabled() else { return raw }
        guard viewMode != .json else { return raw }
        return insertingConversationStartDividerIfNeeded(in: raw, session: session)
    }

    private func insertingConversationStartDividerIfNeeded(in text: String, session: Session) -> String {
        // Avoid double-insertion.
        if text.contains("──────── Conversation starts here") { return text }

        if session.source == .codex {
            let marker = "</INSTRUCTIONS>"
            guard let markerRange = text.range(of: marker) else { return text }

            // Insert divider immediately above the first non-empty line after </INSTRUCTIONS>.
            var idx = markerRange.upperBound
            while idx < text.endIndex {
                let ch = text[idx]
                if ch == "\n" || ch == "\r" || ch == " " || ch == "\t" {
                    idx = text.index(after: idx)
                    continue
                }
                break
            }
            guard idx < text.endIndex else { return text }

            let dividerLine = "──────── Conversation starts here ────────\n"
            var out = text
            out.insert(contentsOf: dividerLine, at: idx)
            return out
        }

        if session.source == .claude {
            // Claude Code: insert divider above the first real user prompt after the local-command caveat transcript.
            let anchor = "caveat: the messages below were generated by the user while running local commands"
            let hasCaveat = session.events.contains(where: { $0.kind == .user && ($0.text?.lowercased().contains(anchor) ?? false) })
            guard hasCaveat else { return text }

            func lineStartIndex(for needle: String) -> String.Index? {
                guard let r = text.range(of: needle) else { return nil }
                var start = r.lowerBound
                while start > text.startIndex {
                    let prev = text.index(before: start)
                    if text[prev] == "\n" { break }
                    start = prev
                }
                return start
            }

            // Prefer: prompt tail extracted from the caveat-containing user event.
            for ev in session.events where ev.kind == .user {
                guard let raw = ev.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
                if raw.lowercased().contains(anchor) {
                    if let tail = Session.claudeLocalCommandPromptTail(from: raw),
                       let idx = lineStartIndex(for: tail) {
                        let dividerLine = "──────── Conversation starts here ────────\n"
                        var out = text
                        out.insert(contentsOf: dividerLine, at: idx)
                        return out
                    }
                    break
                }
            }

            // Fallback: first user line that isn't a caveat/transcript fragment.
            for ev in session.events where ev.kind == .user {
                guard let raw = ev.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
                let lower = raw.lowercased()
                if lower.contains(anchor) { continue }
                if Session.isAgentsPreambleText(raw) { continue }
                if let idx = lineStartIndex(for: raw) {
                    let dividerLine = "──────── Conversation starts here ────────\n"
                    var out = text
                    out.insert(contentsOf: dividerLine, at: idx)
                    return out
                }
            }
        }

        if session.source == .droid {
            func lineStartIndex(for needle: String) -> String.Index? {
                guard let r = text.range(of: needle) else { return nil }
                var start = r.lowerBound
                while start > text.startIndex {
                    let prev = text.index(before: start)
                    if text[prev] == "\n" { break }
                    start = prev
                }
                return start
            }

            var sawPreamble = false
            for ev in session.events where ev.kind == .user {
                guard let raw = ev.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
                if Session.isAgentsPreambleText(raw) {
                    sawPreamble = true
                    continue
                }
                guard sawPreamble else { break }
                if let idx = lineStartIndex(for: raw) {
                    let dividerLine = "──────── Conversation starts here ────────\n"
                    var out = text
                    out.insert(contentsOf: dividerLine, at: idx)
                    return out
                }
            }
        }

        return text
    }

    private func conversationStartRangeForJump(text: String) -> NSRange? {
        let marker = "</INSTRUCTIONS>"
        guard let markerRange = text.range(of: marker) else { return nil }
        // Prefer scrolling to the divider line itself so it lands as the top visible line.
        let divider = "──────── Conversation starts here"
        let suffix = text[markerRange.upperBound...]
        if let div = suffix.range(of: divider) {
            let start = div.lowerBound
            let end = text.index(after: start)
            return NSRange(start..<end, in: text)
        }

        // Fallback: first non-whitespace character after the marker.
        var idx = markerRange.upperBound
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\n" || ch == "\r" || ch == " " || ch == "\t" {
                idx = text.index(after: idx)
                continue
            }
            break
        }
        guard idx < text.endIndex else { return nil }
        return NSRange(idx..<text.index(after: idx), in: text)
    }
}

private enum SelectionScrollMode {
    case ensureVisible
    case alignTop
}

// Build a single pretty-printed JSON array for the entire session.
private func prettyJSONForSession(_ session: Session) -> String {
    guard !session.events.isEmpty else { return "[]" }

    // Hard cap on JSON size for pretty-printing to avoid UI stalls.
    // We keep the total under ~300k UTF-16 units, then append a synthetic
    // sentinel object if we had to truncate.
    var pieces: [String] = []
    var remainingBudget = 300_000
    var omittedCount = 0

    for (idx, e) in session.events.enumerated() {
        let rawPayload = jsonPayload(for: e)
        let payload = transformJSONForViewer(rawPayload)
        let cost = payload.utf16.count + 2 // comma/newline overhead
        if cost <= remainingBudget {
            pieces.append(payload)
            remainingBudget -= cost
        } else {
            // If a single event is too large, do not discard the rest of the session.
            // Emit a compact stub marker for this event and continue if it fits.
            let originalChars = rawPayload.utf16.count
            let stub = #"{"type":"omitted","text":"[Large JSON event truncated - \#(originalChars) chars]","event_index":\#(idx)}"#
            let stubCost = stub.utf16.count + 2
            if stubCost <= remainingBudget {
                pieces.append(stub)
                remainingBudget -= stubCost
                continue
            }

            omittedCount = session.events.count - idx
            break
        }
    }

    if omittedCount > 0 {
        let marker = #"{"type":"omitted","text":"[JSON view truncated - \#(omittedCount) events omitted]"}"#
        pieces.append(marker)
    }

    let joined = "[" + pieces.joined(separator: ",") + "]"
    return PrettyJSON.prettyPrinted(joined)
}

// Decode per-event rawJSON; handles plain JSON and base64-wrapped JSON.
private func jsonPayload(for event: SessionEvent) -> String {
    let raw = event.rawJSON
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
        return trimmed
    }
    if let data = Data(base64Encoded: trimmed),
       let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return trimmed
}

/// Transform per-event JSON for the viewer:
/// - Replace large opaque `encrypted_content` blobs with a compact stub object.
/// - Expand `content[].text` blocks into structured text stubs for readability.
///
/// - Note: This only affects the JSON *presentation* in the viewer. The underlying
///   `SessionEvent.rawJSON` remains unchanged on disk.
private func transformJSONForViewer(_ json: String) -> String {
    // Fast path: only bother parsing when we see fields we care about or the
    // payload is large enough that we may want to stub huge strings for UI safety.
    let isLargePayload = json.utf16.count > 60_000
    guard isLargePayload
        || json.contains(#""encrypted_content""#)
        || json.contains(#""content""#)
        || json.contains(#""resultDisplay""#)
        || json.contains(#""stdout""#)
        || json.contains(#""stderr""#)
        || json.contains(#""url""#)
    else {
        return json
    }
    guard let data = json.data(using: .utf8) else { return json }

    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let transformed = transformJSONValue(object)
        let transformedData = try JSONSerialization.data(withJSONObject: transformed, options: [])
        return String(data: transformedData, encoding: .utf8) ?? json
    } catch {
        return json
    }
}

/// Recursively walk the JSON structure and:
/// - Replace any `"encrypted_content": "<blob>"` string with a descriptor object.
/// - Replace `content[].text` blocks (input/output text) with structured text stubs.
private func transformJSONValue(_ value: Any) -> Any {
    if let string = value as? String {
        if string.utf16.count > 40_000 {
            return makeLargeStringStub(from: string)
        }
        return string
    }

    if let array = value as? [Any] {
        return array.map { transformJSONValue($0) }
    }

    guard let dict = value as? [String: Any] else {
        return value
    }

    var updated: [String: Any] = [:]
    for (key, rawValue) in dict {
        if key == "encrypted_content", let blob = rawValue as? String {
            updated[key] = makeEncryptedContentStub(from: blob, in: dict)
        } else if key == "resultDisplay",
                  let text = rawValue as? String,
                  text.count > 200,
                  text.contains("\n") {
            updated[key] = makeTextBlockStub(from: text)
        } else if key == "stdout",
                  let text = rawValue as? String,
                  text.count > 200,
                  text.contains("\n") {
            updated[key] = makeTextBlockStub(from: text)
        } else if key == "stderr",
                  let text = rawValue as? String,
                  text.count > 200,
                  text.contains("\n") {
            updated[key] = makeTextBlockStub(from: text)
        } else if key == "text",
                  let text = rawValue as? String,
                  shouldConvertTextBlock(in: dict) {
            updated[key] = makeTextBlockStub(from: text)
        } else if key == "output",
                  let text = rawValue as? String,
                  shouldConvertOutputBlock(text: text, in: dict) {
            updated[key] = makeTextBlockStub(from: text)
        } else if key == "url",
                  let url = rawValue as? String,
                  shouldRedactDataURL(url, in: dict) {
            updated[key] = makeDataURLStub(from: url, in: dict)
        } else {
            updated[key] = transformJSONValue(rawValue)
        }
    }
    return updated
}

/// Build a small, JSON-serializable descriptor for an encrypted blob.
/// We assume `encrypted_content` is base64-encoded, so we can approximate byte size.
private func makeEncryptedContentStub(from base64: String, in container: [String: Any]) -> [String: Any] {
    let length = base64.count
    let approxBytes = approximateBase64Bytes(forLength: length, string: base64)
    let approxKB = (Double(approxBytes) / 1024.0 * 10.0).rounded() / 10.0

    var stub: [String: Any] = [
        "_kind": "encrypted_blob",
        "encoding": "base64",
        "bytes": approxBytes,
        "approx_kb": approxKB
    ]

    if let contentType = container["content_type"] as? String {
        stub["content_type"] = contentType
    } else if let mimeType = container["mime_type"] as? String {
        stub["content_type"] = mimeType
    }

    return stub
}

/// Decide whether a `"text"` field should be promoted to a structured text block
/// for readability in the viewer. We currently focus on content parts like:
///   { "type": "input_text", "text": "..." }
private func shouldConvertTextBlock(in container: [String: Any]) -> Bool {
    guard let type = container["type"] as? String else { return false }
    switch type {
    case "input_text", "output_text":
        return true
    default:
        return false
    }
}

/// Decide whether an `"output"` string should be promoted to a structured text block.
/// This is mainly for large tool outputs (e.g., Gemini ReadFile responses) so that
/// multi-line content becomes readable.
private func shouldConvertOutputBlock(text: String, in container: [String: Any]) -> Bool {
    // Only consider reasonably large, multi-line strings.
    guard text.count > 200 else { return false }
    guard text.contains("\n") else { return false }

    // Avoid touching numeric-style outputs; these are almost always human text blobs.
    if let _ = container["output_tokens"] as? NSNumber {
        return false
    }
    return true
}

/// Decide whether a `url` string is an inline data: URL that should be summarized
/// to avoid rendering a huge base64 blob (e.g., embedded images).
private func shouldRedactDataURL(_ url: String, in container: [String: Any]) -> Bool {
    guard url.count > 100 else { return false }
    guard url.hasPrefix("data:") else { return false }
    guard url.contains(";base64,") else { return false }
    return true
}

/// Build a small descriptor for an inline data URL (typically an image) so the JSON
/// view shows media type and size instead of the full base64 string.
private func makeDataURLStub(from url: String, in container: [String: Any]) -> [String: Any] {
    // data:<mediaType>;base64,<payload>
    let prefix = "data:"
    guard url.hasPrefix(prefix),
          let semicolon = url.firstIndex(of: ";"),
          let comma = url.firstIndex(of: ","),
          semicolon < comma
    else {
        return [
            "_kind": "data_url_blob",
            "length": url.count
        ]
    }

    let mediaStart = url.index(url.startIndex, offsetBy: prefix.count)
    let mediaType = String(url[mediaStart..<semicolon])
    let base64Start = url.index(after: comma)
    let base64Payload = String(url[base64Start...])
    let approxBytes = approximateBase64Bytes(forLength: base64Payload.count, string: base64Payload)
    let approxKB = (Double(approxBytes) / 1024.0 * 10.0).rounded() / 10.0

    var stub: [String: Any] = [
        "_kind": "data_url_blob",
        "media_type": mediaType,
        "encoding": "base64",
        "bytes": approxBytes,
        "approx_kb": approxKB
    ]

    if let role = container["type"] as? String {
        stub["context_type"] = role
    }

    return stub
}

/// Build a structured representation for large text blocks so that the JSON view
/// shows them as readable paragraphs instead of a single escaped blob.
private func makeTextBlockStub(from text: String) -> [String: Any] {
    let length = text.utf16.count

    // Avoid exploding very large text (e.g., "ls -R" tool output) into thousands of JSON
    // array items. Keep a preview for readability while keeping the JSON view responsive.
    if length > 80_000 {
        let previewLineLimit = 200
        let preview = text.split(
            separator: "\n",
            maxSplits: previewLineLimit - 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        let newlineCount = text.utf8.reduce(0) { partial, byte in
            partial + (byte == 10 ? 1 : 0)
        }
        let lineCount = newlineCount + 1
        return [
            "_kind": "text_block",
            "preview_lines": preview,
            "preview_line_count": preview.count,
            "line_count": lineCount,
            "chars": length,
            "truncated": true
        ]
    }

    let lines = text.components(separatedBy: .newlines)
    return [
        "_kind": "text_block",
        "lines": lines,
        "line_count": lines.count,
        "chars": length
    ]
}

private func makeLargeStringStub(from text: String) -> [String: Any] {
    let length = text.utf16.count
    let previewLimit = 2_000
    let preview = String(text.prefix(previewLimit))
    return [
        "_kind": "string_preview",
        "chars": length,
        "preview_chars": preview.utf16.count,
        "preview": preview,
        "truncated": true
    ]
}

/// Approximate decoded bytes for a Base64 string based on its length and padding.
private func approximateBase64Bytes(forLength length: Int, string: String) -> Int {
    guard length > 0 else { return 0 }
    // Base64 pads with up to two '=' characters at the end.
    let padding = string.suffix(2).reduce(0) { partial, char in
        partial + (char == "=" ? 1 : 0)
    }
    let raw = (length * 3) / 4 - padding
    return max(raw, 0)
}

// Lightweight JSON tokenizer for syntax highlighting.
// Returns: keys, string values, numbers, booleans/null.
private func jsonSyntaxHighlightRanges(for text: String) -> ([NSRange], [NSRange], [NSRange], [NSRange]) {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    if full.length == 0 {
        return ([], [], [], [])
    }

    var keyRanges: [NSRange] = []
    var stringRanges: [NSRange] = []
    var numberRanges: [NSRange] = []
    var keywordRanges: [NSRange] = []

    // Keys: any string directly followed by a colon.
    if let keyRegex = try? NSRegularExpression(
        pattern: "\"([^\"\\\\]|\\\\.)*\"(?=\\s*:)",
        options: []
    ) {
        for match in keyRegex.matches(in: text, options: [], range: full) {
            let r = match.range
            if r.location != NSNotFound && r.length > 0 {
                keyRanges.append(r)
            }
        }
    }

    // All strings
    var allStringRanges: [NSRange] = []
    if let strRegex = try? NSRegularExpression(
        pattern: "\"([^\"\\\\]|\\\\.)*\"",
        options: []
    ) {
        for match in strRegex.matches(in: text, options: [], range: full) {
            let r = match.range
            if r.location != NSNotFound && r.length > 0 {
                allStringRanges.append(r)
            }
        }
    }
    // Value strings = all strings minus key strings
    outer: for r in allStringRanges {
        for k in keyRanges {
            if NSIntersectionRange(k, r).length > 0 {
                continue outer
            }
        }
        stringRanges.append(r)
    }

    // Numbers
    if let numRegex = try? NSRegularExpression(
        pattern: "(?<![\\w\".-])(-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)",
        options: []
    ) {
        for match in numRegex.matches(in: text, options: [], range: full) {
            let r = match.range(at: 1)
            if r.location != NSNotFound && r.length > 0 {
                numberRanges.append(r)
            }
        }
    }

    // true / false / null
    if let kwRegex = try? NSRegularExpression(
        pattern: "\\b(true|false|null)\\b",
        options: []
    ) {
        for match in kwRegex.matches(in: text, options: [], range: full) {
            let r = match.range(at: 1)
            if r.location != NSNotFound && r.length > 0 {
                keywordRanges.append(r)
            }
        }
    }

    return (keyRanges, stringRanges, numberRanges, keywordRanges)
}

private struct PlainTextScrollView: NSViewRepresentable {
    let text: String
    let selection: NSRange?
    let selectionScrollMode: SelectionScrollMode
    let fontSize: CGFloat
    let highlights: [NSRange]
    let currentIndex: Int
    let commandRanges: [NSRange]
    let userRanges: [NSRange]
    let assistantRanges: [NSRange]
    let outputRanges: [NSRange]
    let errorRanges: [NSRange]
    let isJSONMode: Bool
    let appAppearanceRaw: String
    let colorScheme: ColorScheme
    let monochrome: Bool

    class Coordinator {
        var lastWidth: CGFloat = 0
        var lastPaintedHighlights: [NSRange] = []
        var lastPaintedIndex: Int = -1
        var lastAppearanceRaw: String = ""
        var lastColorScheme: ColorScheme?
        var lastIsJSONMode: Bool = false
        var lastMonochrome: Bool = false
        var lastColorSignature: (Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        // Enable non-contiguous layout for better performance on large documents
        textView.layoutManager?.allowsNonContiguousLayout = true

        // Explicitly set appearance to match app preference
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        switch appAppearance {
        case .light:
            scroll.appearance = NSAppearance(named: .aqua)
            textView.appearance = NSAppearance(named: .aqua)
        case .dark:
            scroll.appearance = NSAppearance(named: .darkAqua)
            textView.appearance = NSAppearance(named: .darkAqua)
        case .system:
            scroll.appearance = nil
            textView.appearance = nil
        }
        context.coordinator.lastAppearanceRaw = appAppearanceRaw
        context.coordinator.lastColorScheme = colorScheme

        // Set background with proper dark mode support
        let isDark = (textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let baseBackground: NSColor = isDark ? NSColor(white: 0.15, alpha: 1.0) : NSColor.textBackgroundColor

        // Apply dimming effect when Find is active (like Apple Notes)
        if !highlights.isEmpty {
            textView.backgroundColor = isDark ? NSColor(white: 0.12, alpha: 1.0) : NSColor.black.withAlphaComponent(0.08)
        } else {
            textView.backgroundColor = baseBackground
        }

        textView.string = text
        applySyntaxColors(textView)
        applyFindHighlights(textView, coordinator: context.coordinator)

        scroll.documentView = textView
        if let sel = selection {
            scrollSelection(textView, range: sel, mode: selectionScrollMode)
            // Clear selection immediately to avoid blue highlight - we use yellow/white backgrounds instead
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? NSTextView {
            let textChanged = tv.string != text
            let appearanceChanged = context.coordinator.lastAppearanceRaw != appAppearanceRaw
            let schemeChanged = context.coordinator.lastColorScheme != colorScheme
            let modeChanged = context.coordinator.lastIsJSONMode != isJSONMode
            let monochromeChanged = context.coordinator.lastMonochrome != monochrome
            let colorSignature = (
                commandRanges.count,
                userRanges.count,
                assistantRanges.count,
                outputRanges.count,
                errorRanges.count
            )
            let colorsChanged = colorSignature != context.coordinator.lastColorSignature

            // Explicitly set NSView appearance when app appearance changes
            if appearanceChanged {
                let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
                switch appAppearance {
                case .light:
                    nsView.appearance = NSAppearance(named: .aqua)
                    tv.appearance = NSAppearance(named: .aqua)
                case .dark:
                    nsView.appearance = NSAppearance(named: .darkAqua)
                    tv.appearance = NSAppearance(named: .darkAqua)
                case .system:
                    nsView.appearance = nil
                    tv.appearance = nil
                }
                context.coordinator.lastAppearanceRaw = appAppearanceRaw
            }

            if textChanged {
                tv.string = text
                context.coordinator.lastPaintedHighlights = []
            }

            // Reapply colors when text, appearance, mode, monochrome, or ranges change
            if textChanged || appearanceChanged || schemeChanged || modeChanged || monochromeChanged || colorsChanged {
                applySyntaxColors(tv)
            }

            if let font = tv.font, abs(font.pointSize - fontSize) > 0.5 {
                tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }

            // Set background with proper dark mode support
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let baseBackground: NSColor = isDark ? NSColor(white: 0.15, alpha: 1.0) : NSColor.textBackgroundColor

            // Apply/remove dimming effect based on Find state (like Apple Notes)
            if !highlights.isEmpty {
                tv.backgroundColor = isDark ? NSColor(white: 0.12, alpha: 1.0) : NSColor.black.withAlphaComponent(0.08)
            } else {
                tv.backgroundColor = baseBackground
            }

            let width = max(1, nsView.contentSize.width)
            tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            tv.setFrameSize(NSSize(width: width, height: tv.frame.size.height))

            // Scroll to current match if any
            if let sel = selection {
                scrollSelection(tv, range: sel, mode: selectionScrollMode)
                // Clear selection immediately to avoid blue highlight - we use yellow/white backgrounds instead
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }

            applyFindHighlights(tv, coordinator: context.coordinator)

            // Update last seen scheme at the end of the pass
            context.coordinator.lastColorScheme = colorScheme
            context.coordinator.lastIsJSONMode = isJSONMode
            context.coordinator.lastMonochrome = monochrome
            context.coordinator.lastColorSignature = colorSignature
        }
    }

    private func scrollSelection(_ tv: NSTextView, range: NSRange, mode: SelectionScrollMode) {
        switch mode {
        case .ensureVisible:
            tv.scrollRangeToVisible(range)
        case .alignTop:
            scrollRangeToTop(tv, range: range)
        }
    }

    private func scrollRangeToTop(_ tv: NSTextView, range: NSRange) {
        guard let scrollView = tv.enclosingScrollView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else {
            tv.scrollRangeToVisible(range)
            return
        }

        lm.ensureLayout(for: tc)
        let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
        // Translate into view coordinates.
        let origin = tv.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y

        // Align the target line to the top, leaving a small breathing room equal to the text inset.
        let padding = max(0, tv.textContainerInset.height)
        let y = max(0, rect.minY - padding)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // Apply syntax colors once when text changes (full document)
    private func applySyntaxColors(_ tv: NSTextView) {
        guard let textStorage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)

        #if DEBUG
        print("🎨 SYNTAX: cmd=\(commandRanges.count) user=\(userRanges.count) asst=\(assistantRanges.count) out=\(outputRanges.count) err=\(errorRanges.count)")
        #endif

        textStorage.beginEditing()

        // Clear only foreground colors (not background - that's for find highlights)
        textStorage.removeAttribute(.foregroundColor, range: full)

        // Set base text color for all text (soft white in dark mode)
        let isDarkMode = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let baseColor = isDarkMode ? NSColor(white: 0.92, alpha: 1.0) : NSColor.labelColor
        textStorage.addAttribute(.foregroundColor, value: baseColor, range: full)

        if isJSONMode {
            // JSON syntax palette (approximate Xcode-style):
            // - Keys: pink
            // - String values: blue
            // - Numbers: green
            // - true/false/null: purple
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

            if !commandRanges.isEmpty {
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.45, alpha: 1.0)  // JSON keys in gray
                    } else {
                        let basePink = NSColor.systemPink
                        if isDarkMode || increaseContrast { return basePink }
                        return basePink.withAlphaComponent(0.95)
                    }
                }()
                for r in commandRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
            if !userRanges.isEmpty {
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.55, alpha: 1.0)  // JSON strings in gray
                    } else {
                        let baseBlue = NSColor.systemBlue
                        if isDarkMode || increaseContrast { return baseBlue }
                        return baseBlue.withAlphaComponent(0.9)
                    }
                }()
                for r in userRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
            if !outputRanges.isEmpty {
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.65, alpha: 1.0)  // JSON numbers in gray
                    } else {
                        let baseGreen = NSColor.systemGreen
                        if isDarkMode || increaseContrast { return baseGreen }
                        return baseGreen.withAlphaComponent(0.9)
                    }
                }()
                for r in outputRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
            if !assistantRanges.isEmpty {
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.35, alpha: 1.0)  // JSON keywords in gray
                    } else {
                        let basePurple = NSColor.systemPurple
                        if isDarkMode || increaseContrast { return basePurple }
                        return basePurple.withAlphaComponent(0.9)
                    }
                }()
                for r in assistantRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        } else {
            // Terminal transcript palette
            // Command colorization (foreground) – orange for high distinction
            if !commandRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.4, alpha: 1.0)  // Commands in darker gray
                    } else {
                        let baseOrange = NSColor.systemOrange
                        if isDark || increaseContrast { return baseOrange }
                        return baseOrange.withAlphaComponent(0.95)
                    }
                }()
                for r in commandRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
            // User input colorization (blue)
            if !userRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.5, alpha: 1.0)  // User input in medium gray
                    } else {
                        let baseBlue = NSColor.systemBlue
                        if isDark || increaseContrast { return baseBlue }
                        return baseBlue.withAlphaComponent(0.9)
                    }
                }()
                for r in userRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
            // Assistant response colorization (subtle gray - less prominent)
            if !assistantRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let baseGray = NSColor.secondaryLabelColor
                let gray: NSColor = {
                    if isDark || increaseContrast { return baseGray }
                    return baseGray.withAlphaComponent(0.8)
                }()
                for r in assistantRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: gray, range: r)
                }
            }
            // Tool output colorization (teal/cyan family for contrast with orange)
            if !outputRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.6, alpha: 1.0)  // Tool output in lighter gray
                    } else {
                        let baseTeal = NSColor.systemTeal
                        if isDark || increaseContrast { return baseTeal }
                        return baseTeal.withAlphaComponent(0.90)
                    }
                }()
                    for r in outputRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
            // Error colorization (red)
            if !errorRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let color: NSColor = {
                    if monochrome {
                        return NSColor(white: 0.3, alpha: 1.0)  // Errors in darkest gray for emphasis
                    } else {
                        let baseRed = NSColor.systemRed
                        if isDark || increaseContrast { return baseRed }
                        return baseRed.withAlphaComponent(0.9)
                    }
                }()
                for r in errorRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }

        textStorage.endEditing()
    }

    // Apply find highlights with scoped layout/invalidation for performance
    private func applyFindHighlights(_ tv: NSTextView, coordinator: Coordinator) {
        assert(Thread.isMainThread, "applyFindHighlights must be called on main thread")

        guard let textStorage = tv.textStorage,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else {
            print("⚠️ FIND: Missing textStorage/layoutManager/textContainer")
            return
        }

        let full = NSRange(location: 0, length: (tv.string as NSString).length)

        // Check if highlights or the current index changed
        let highlightsChanged = coordinator.lastPaintedHighlights != highlights || coordinator.lastPaintedIndex != currentIndex

        print("🔍 FIND: highlights=\(highlights.count), lastPainted=\(coordinator.lastPaintedHighlights.count), changed=\(highlightsChanged), currentIndex=\(currentIndex)")

        if !highlightsChanged {
            // Just show indicator, attributes already correct
            if !highlights.isEmpty && currentIndex < highlights.count {
                tv.showFindIndicator(for: highlights[currentIndex])
            }
            return
        }

        // Get visible range for scoped invalidation/layout (performance optimization)
        // IMPORTANT: glyphRange(forBoundingRect:in:) expects container coordinates, not view coordinates
        let visRectView = tv.enclosingScrollView?.contentView.documentVisibleRect ?? tv.visibleRect
        let origin = tv.textContainerOrigin
        let visRectInContainer = visRectView.offsetBy(dx: -origin.x, dy: -origin.y)
        var visGlyphs = lm.glyphRange(forBoundingRect: visRectInContainer, in: tc)
        var visChars = lm.characterRange(forGlyphRange: visGlyphs, actualGlyphRange: nil)
        // Fallback: if visible character range is empty (can happen during layout churn), widen to a reasonable window
        if visChars.length == 0 {
            visChars = NSIntersectionRange(full, NSRange(location: max(0, tv.selectedRange().location - 2000), length: 4000))
            visGlyphs = lm.glyphRange(forCharacterRange: visChars, actualCharacterRange: nil)
        }

        print("🔍 VISIBLE: visChars.length=\(visChars.length), visChars=\(visChars)")

        textStorage.beginEditing()

        // Clear ALL old highlights (full document - ensures clean slate)
        for r in coordinator.lastPaintedHighlights {
            if NSMaxRange(r) <= full.length {
                textStorage.removeAttribute(.backgroundColor, range: r)
            }
        }

        // Paint ALL new highlights (full document - ensures they're present when scrolling)
        let currentBG = NSColor(deviceRed: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)  // Yellow
        let otherBG = NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.9)     // White
        let matchFG = NSColor.black
        for (i, r) in highlights.enumerated() {
            if NSMaxRange(r) <= full.length {
                let bg = (i == currentIndex) ? currentBG : otherBG
                textStorage.addAttribute(.backgroundColor, value: bg, range: r)
                textStorage.addAttribute(.foregroundColor, value: matchFG, range: r)
            }
        }

        textStorage.endEditing()

        // Fix attributes only in VISIBLE region (performance win). Avoid clearing backgrounds.
        textStorage.fixAttributes(in: visChars)

        // Invalidate only VISIBLE region (performance win)
        lm.invalidateDisplay(forCharacterRange: visChars)

        // Layout only VISIBLE region (BIG performance win - avoids full-document layout thrashing)
        let glyphRange = lm.glyphRange(forCharacterRange: visChars, actualCharacterRange: nil)
        lm.ensureLayout(forGlyphRange: glyphRange)

        tv.setNeedsDisplay(visRectView)

        print("✅ FIND: Painted \(highlights.count) highlights, visibleRange=\(visChars)")

        // Update cache
        coordinator.lastPaintedHighlights = highlights

        // Show Apple Notes-style find indicator for current match
        if !highlights.isEmpty && currentIndex < highlights.count {
            tv.showFindIndicator(for: highlights[currentIndex])
        }

        coordinator.lastPaintedIndex = currentIndex
    }
}

private struct WholeSessionRawPrettySheet: View {
    let session: Session?
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Int = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("Pretty").tag(0)
                Text("Raw JSON").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(8)
            Divider()
            ScrollView {
                if let s = session {
                    let raw = s.events.map { $0.rawJSON }.joined(separator: "\n")
                    let pretty = prettyJSONForSession(s)
                    if tab == 0 {
                        Text(pretty).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12)
                    } else {
                        Text(raw).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12)
                    }
                } else {
                    ContentUnavailableView("No session", systemImage: "doc")
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() } }.padding(8)
        }
        .frame(width: 720, height: 520)
    }
}
