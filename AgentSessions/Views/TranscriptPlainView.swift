import SwiftUI
import AppKit
import Foundation

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
    @Environment(\.colorScheme) private var colorScheme
    let sessionID: String?
    let sessionIDExtractor: (Session) -> String?  // Extract ID for clipboard
    let sessionIDLabel: String  // "Codex" or "Claude"
    let enableCaching: Bool  // Codex uses cache, Claude doesn't

    // Plain transcript buffer
    @State private var transcript: String = ""

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
    @State private var showLegendPopover: Bool = false
    @State private var isBuildingJSON: Bool = false

    // Toggles (view-scoped)
    @State private var showTimestamps: Bool = false
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.normal.rawValue
    @AppStorage("SessionViewMode") private var viewModeRaw: String = SessionViewMode.transcript.rawValue
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

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
    // Ephemeral copy confirmation (popover)
    @State private var showIDCopiedPopover: Bool = false

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
                    PlainTextScrollView(
                        text: transcript,
                        selection: selectedNSRange,
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
                        colorScheme: colorScheme
                    )

                    // Inline notice for sessions without commands when in Terminal mode
                    if shouldColorize && !hasCommands {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                            Text("No commands recorded; Terminal matches Transcript")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
                                .shadow(radius: 1)
                        )
                        .padding([.top, .leading], 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                    }

                    // Show animation during lazy load OR full refresh
                    if shouldShowLoadingAnimation {
                        LoadingAnimationView(
                            codexColor: .blue,
                            claudeColor: Color(red: 204/255, green: 121/255, blue: 90/255)
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
                // Only focus if actively transitioning TO transcriptFind (not just because it IS transcriptFind)
                if oldFocus != .transcriptFind && newFocus == .transcriptFind {
                    #if DEBUG
                    print("  ↳ Setting allowFindFocus=true, findFocused=true")
                    #endif
                    allowFindFocus = true
                    findFocused = true
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
            .onReceive(indexer.requestCopyPlainPublisher) { _ in copyAll() }
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
                .hidden()

            // Invisible button to toggle Transcript/Terminal with Cmd+Shift+T
            Button(action: {
                let current = SessionViewMode.from(TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal)
                let next: SessionViewMode
                switch current {
                case .transcript:
                    next = .terminal
                case .terminal:
                    next = .transcript
                case .json:
                    // From JSON, Cmd+Shift+T toggles back to Transcript.
                    next = .transcript
                }
                viewModeRaw = next.rawValue
                renderModeRaw = next.transcriptRenderMode.rawValue
            }) { EmptyView() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .hidden()

            // === LEADING GROUP: View Mode Segmented Control + JSON status ===
            VStack(alignment: .leading, spacing: 2) {
                Picker("View Style", selection: $viewModeRaw) {
                    Text("Transcript").tag(SessionViewMode.transcript.rawValue)
                    Text("Terminal").tag(SessionViewMode.terminal.rawValue)
                    Text("JSON").tag(SessionViewMode.json.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 200)
                .accessibilityLabel("View Style")
                .help("Switch between Transcript, Terminal, and JSON views. Terminal colors: blue=user, gray=assistant, orange=command, teal=[out] output, red=error.")

                if isJSONMode && isBuildingJSON {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text("Building JSON view…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12)

            Button(action: { showLegendPopover.toggle() }) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show Terminal color legend")
            .popover(isPresented: $showLegendPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Terminal Legend").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) { Text("> user").foregroundStyle(.blue) }
                    HStack(spacing: 6) { Text("[assistant]").foregroundStyle(.secondary) }
                    HStack(spacing: 6) { Text("› tool: …").foregroundStyle(.orange) }
                    HStack(spacing: 6) { Text("[out] …").foregroundStyle(.teal) }
                    HStack(spacing: 6) { Text("! error …").foregroundStyle(.red) }
                }
                .padding(10)
                .frame(width: 220)
            }

            // System flexible space pushes trailing group to the right
            Spacer()

            // === CENTER: Quiet secondary ID label (click-to-copy) ===
            HStack(spacing: 8) {
                if let fullID = sessionIDExtractor(session) {
                    let displayLast4 = String(fullID.suffix(4))
                    let short = extractShortID(for: session) ?? String(fullID.prefix(6))
                    Button(action: { copySessionID(for: session) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .imageScale(.medium)
                            Text("ID \(displayLast4)")
                                .font(.system(size: 13))
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
                            .font(.system(size: 12))
                    }
                }
            }

            Spacer(minLength: 24)

            // MID: Text size controls (moved next to ID)
            HStack(spacing: 6) {
                Button(action: { adjustFont(-1) }) {
                    HStack(spacing: 2) {
                        Text("A").font(.system(size: 12, weight: .semibold))
                        Text("−").font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("-", modifiers: .command)
                .help("Decrease text size (⌘−)")
                .accessibilityLabel("Decrease Text Size")

                Button(action: { adjustFont(1) }) {
                    HStack(spacing: 2) {
                        Text("A").font(.system(size: 14, weight: .semibold))
                        Text("+").font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 14))
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
                        .focused($findFocused)
                        .focusable(allowFindFocus)
                        .onSubmit { performFind(resetIndex: true) }
                        .accessibilityLabel("Find in transcript")
                        .frame(minWidth: 120, idealWidth: 220, maxWidth: 360)
                    if !findText.isEmpty {
                        Button(action: { findText = ""; performFind(resetIndex: true) }) {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
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
                .onAppear {
                    #if DEBUG
                    print("👁️ FIND BAR ON APPEAR: Setting allowFindFocus=true")
                    #endif
                    allowFindFocus = true
                }

                // Next/Previous controls group
                HStack(spacing: 2) {
                    Button(action: { performFind(resetIndex: false, direction: -1) }) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(findMatches.isEmpty)
                    .help("Previous match (⇧⌘G)")
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Button(action: { performFind(resetIndex: false, direction: 1) }) {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(findMatches.isEmpty)
                    .help("Next match (⌘G)")
                    .keyboardShortcut("g", modifiers: .command)
                }
                
                // Match count badge
                if !findText.isEmpty {
                    Text(findStatus())
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(findMatches.isEmpty ? .red : .secondary)
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
        syncRenderModeWithViewMode()
        let filters: TranscriptFilters = .current(showTimestamps: showTimestamps, showMeta: false)
        let mode = viewMode.transcriptRenderMode
        let buildKey = "\(session.id)|\(session.events.count)|\(viewMode.rawValue)|\(showTimestamps ? 1 : 0)"

        #if DEBUG
        print("🔨 REBUILD: mode=\(mode) shouldColorize=\(shouldColorize) enableCaching=\(enableCaching)")
        #endif

        if enableCaching {
            // Memoization key: session identity, event count, render mode, and timestamp setting
            let key = buildKey
            if lastBuildKey == key { return }
            // Try in-view memo cache first
            if let cached = transcriptCache[key] {
                transcript = cached
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
                }
                lastBuildKey = key
                // Reset find state
                performFind(resetIndex: true)
                selectedNSRange = nil
                updateSelectionToCurrentMatch()
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
                    transcript = t
                    commandRanges = []; userRanges = []; assistantRanges = []; outputRanges = []; errorRanges = []
                    hasCommands = session.events.contains { $0.kind == .tool_call }
                    transcriptCache[key] = t
                    lastBuildKey = key
                    performFind(resetIndex: true)
                    selectedNSRange = nil
                    updateSelectionToCurrentMatch()
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
                            self.transcript = built.0
                            self.commandRanges = built.1
                            self.userRanges = built.2
                            self.assistantRanges = []
                            self.outputRanges = []
                            self.errorRanges = []
                            self.hasCommands = true
                            self.findAdditionalRanges()
                            self.transcriptCache[key] = built.0
                            self.terminalCommandRangesCache[key] = built.1
                            self.terminalUserRangesCache[key] = built.2
                            self.lastBuildKey = key
                            self.performFind(resetIndex: true)
                            self.selectedNSRange = nil
                            self.updateSelectionToCurrentMatch()
                        }
                    } else {
                        let t = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: .normal)
                        await MainActor.run {
                            self.transcript = t
                            self.commandRanges = []
                            self.userRanges = []
                            self.assistantRanges = []
                            self.outputRanges = []
                            self.errorRanges = []
                            self.hasCommands = sessionHasCommands
                            self.transcriptCache[key] = t
                            self.lastBuildKey = key
                            self.performFind(resetIndex: true)
                            self.selectedNSRange = nil
                            self.updateSelectionToCurrentMatch()
                        }
                    }
                }
                return
            }

            // Fallback: synchronous build (legacy behavior)
            let sessionHasCommands = session.events.contains { $0.kind == .tool_call }
            if mode == .terminal && shouldColorize && sessionHasCommands {
                let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
                transcript = built.0
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
                transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: .normal)
                commandRanges = []
                userRanges = []
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                transcriptCache[key] = transcript
                lastBuildKey = key
            }
        } else {
            // No caching (Claude)
            let sessionHasCommands2 = session.events.contains { $0.kind == .tool_call }
            if viewMode == .json {
                scheduleJSONBuild(session: session, key: buildKey, shouldCache: false, hasCommands: sessionHasCommands2)
            } else if viewMode == .terminal && shouldColorize && sessionHasCommands2 {
                let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
                transcript = built.0
                commandRanges = built.1
                userRanges = built.2
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                hasCommands = true
                findAdditionalRanges()
            } else {
                transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: .normal)
                commandRanges = []
                userRanges = []
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                hasCommands = sessionHasCommands2
            }
        }

        // Reset find state
        performFind(resetIndex: true)
        selectedNSRange = nil
        updateSelectionToCurrentMatch()

        // Auto-scroll to first conversational message if skipping preamble is enabled
        let d = UserDefaults.standard
        let skip = (d.object(forKey: "SkipAgentsPreamble") == nil) ? true : d.bool(forKey: "SkipAgentsPreamble")
        if skip, selectedNSRange == nil {
            if let r = firstConversationRangeInTranscript(text: transcript) {
                selectedNSRange = r
            } else if let anchor = firstConversationAnchor(in: session), let rr = transcript.range(of: anchor) {
                selectedNSRange = NSRange(rr, in: transcript)
            }
        }
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
        let q = findText
        guard !q.isEmpty else {
            findMatches = []
            currentMatchIndex = 0
            highlightRanges = []
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
        selectedNSRange = highlightRanges[currentMatchIndex]
    }

    private func findStatus() -> String {
        if findText.isEmpty { return "" }
        if findMatches.isEmpty { return "0/0" }
        return "\(currentMatchIndex + 1)/\(findMatches.count)"
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
        let payload = redactEncryptedContent(inJSON: rawPayload)
        let cost = payload.utf16.count + 2 // comma/newline overhead
        if cost <= remainingBudget {
            pieces.append(payload)
            remainingBudget -= cost
        } else {
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

/// Replace large opaque `encrypted_content` blobs with a compact, structured stub object
/// so the JSON viewer stays readable and fast while still conveying type/size.
///
/// - Note: This only affects the JSON *presentation* in the viewer. The underlying
///   `SessionEvent.rawJSON` remains unchanged on disk.
private func redactEncryptedContent(inJSON json: String) -> String {
    guard json.contains(#""encrypted_content""#) else { return json }
    guard let data = json.data(using: .utf8) else { return json }

    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let redacted = redactEncryptedContentValue(object)
        let redactedData = try JSONSerialization.data(withJSONObject: redacted, options: [])
        return String(data: redactedData, encoding: .utf8) ?? json
    } catch {
        return json
    }
}

/// Recursively walk the JSON structure and replace any `"encrypted_content": "<blob>"`
/// string value with a small descriptor object containing encoding and size metadata.
private func redactEncryptedContentValue(_ value: Any) -> Any {
    if let array = value as? [Any] {
        return array.map { redactEncryptedContentValue($0) }
    }

    guard let dict = value as? [String: Any] else {
        return value
    }

    var updated: [String: Any] = [:]
    for (key, rawValue) in dict {
        if key == "encrypted_content", let blob = rawValue as? String {
            updated[key] = makeEncryptedContentStub(from: blob, in: dict)
        } else {
            updated[key] = redactEncryptedContentValue(rawValue)
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

    class Coordinator {
        var lastWidth: CGFloat = 0
        var lastPaintedHighlights: [NSRange] = []
        var lastPaintedIndex: Int = -1
        var lastAppearanceRaw: String = ""
        var lastColorScheme: ColorScheme?
        var lastIsJSONMode: Bool = false
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
            textView.scrollRangeToVisible(sel)
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

            // Reapply colors when text, appearance, mode, or ranges change
            if textChanged || appearanceChanged || schemeChanged || modeChanged || colorsChanged {
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
                tv.scrollRangeToVisible(sel)
                // Clear selection immediately to avoid blue highlight - we use yellow/white backgrounds instead
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }

            applyFindHighlights(tv, coordinator: context.coordinator)

            // Update last seen scheme at the end of the pass
            context.coordinator.lastColorScheme = colorScheme
            context.coordinator.lastIsJSONMode = isJSONMode
            context.coordinator.lastColorSignature = colorSignature
        }
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
                let basePink = NSColor.systemPink
                let pink: NSColor = {
                    if isDarkMode || increaseContrast { return basePink }
                    return basePink.withAlphaComponent(0.95)
                }()
                for r in commandRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: pink, range: r)
                }
            }
            if !userRanges.isEmpty {
                let baseBlue = NSColor.systemBlue
                let blue: NSColor = {
                    if isDarkMode || increaseContrast { return baseBlue }
                    return baseBlue.withAlphaComponent(0.9)
                }()
                for r in userRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: blue, range: r)
                }
            }
            if !outputRanges.isEmpty {
                let baseGreen = NSColor.systemGreen
                let green: NSColor = {
                    if isDarkMode || increaseContrast { return baseGreen }
                    return baseGreen.withAlphaComponent(0.9)
                }()
                for r in outputRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: green, range: r)
                }
            }
            if !assistantRanges.isEmpty {
                let basePurple = NSColor.systemPurple
                let purple: NSColor = {
                    if isDarkMode || increaseContrast { return basePurple }
                    return basePurple.withAlphaComponent(0.9)
                }()
                for r in assistantRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: purple, range: r)
                }
            }
        } else {
            // Terminal transcript palette
            // Command colorization (foreground) – orange for high distinction
            if !commandRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let baseOrange = NSColor.systemOrange
                let orange: NSColor = {
                    if isDark || increaseContrast { return baseOrange }
                    return baseOrange.withAlphaComponent(0.95)
                }()
                for r in commandRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: orange, range: r)
                }
            }
            // User input colorization (blue)
            if !userRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let baseBlue = NSColor.systemBlue
                let blue: NSColor = {
                    if isDark || increaseContrast { return baseBlue }
                    return baseBlue.withAlphaComponent(0.9)
                }()
                for r in userRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: blue, range: r)
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
                let baseTeal = NSColor.systemTeal
                let teal: NSColor = {
                    if isDark || increaseContrast { return baseTeal }
                    return baseTeal.withAlphaComponent(0.90)
                }()
                    for r in outputRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: teal, range: r)
                }
            }
            // Error colorization (red)
            if !errorRanges.isEmpty {
                let isDark = isDarkMode
                let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let baseRed = NSColor.systemRed
                let red: NSColor = {
                    if isDark || increaseContrast { return baseRed }
                    return baseRed.withAlphaComponent(0.9)
                }()
                for r in errorRanges where NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: red, range: r)
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
