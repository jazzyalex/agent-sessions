import SwiftUI
import AppKit

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

    // Toggles (view-scoped)
    @State private var showTimestamps: Bool = false
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.normal.rawValue
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    // Auto-colorize in Terminal mode
    private var shouldColorize: Bool {
        return renderModeRaw == TranscriptRenderMode.terminal.rawValue
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
        return (indexer.isLoadingSession && indexer.loadingSessionID == id) || indexer.isIndexing
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
                        commandRanges: shouldColorize ? commandRanges : [],
                        userRanges: shouldColorize ? userRanges : [],
                        assistantRanges: shouldColorize ? assistantRanges : [],
                        outputRanges: shouldColorize ? outputRanges : [],
                        errorRanges: shouldColorize ? errorRanges : [],
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
            .onChange(of: renderModeRaw) { _, _ in rebuild(session: session) }
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

            // Invisible button to toggle view mode with Cmd+Shift+T
            Button(action: {
                renderModeRaw = (renderModeRaw == TranscriptRenderMode.normal.rawValue)
                    ? TranscriptRenderMode.terminal.rawValue
                    : TranscriptRenderMode.normal.rawValue
            }) { EmptyView() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .hidden()

            // === LEADING GROUP: View Mode Segmented Control ===
            Picker("View Style", selection: $renderModeRaw) {
                Text("Transcript")
                    .tag(TranscriptRenderMode.normal.rawValue)
                Text("Terminal")
                    .tag(TranscriptRenderMode.terminal.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .frame(width: 200)
            .accessibilityLabel("View Style")
            .help("Switch between Transcript and Terminal view (⌘⇧T). Terminal colors: blue=user, gray=assistant, orange=command, teal=[out] output, red=error.")
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
        let filters: TranscriptFilters = .current(showTimestamps: showTimestamps, showMeta: false)
        let mode = TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal

        #if DEBUG
        print("🔨 REBUILD: mode=\(mode) shouldColorize=\(shouldColorize) enableCaching=\(enableCaching)")
        #endif

        if enableCaching {
            // Memoization key: session identity, event count, render mode, and timestamp setting
            let key = "\(session.id)|\(session.events.count)|\(renderModeRaw)|\(showTimestamps ? 1 : 0)"
            if lastBuildKey == key { return }
            // Try in-view memo cache first
            if let cached = transcriptCache[key] {
                transcript = cached
                if mode == .terminal && shouldColorize {
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
                    if mode == .terminal && shouldColorize {
                        let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
                        await MainActor.run {
                            self.transcript = built.0
                            self.commandRanges = built.1
                            self.userRanges = built.2
                            self.assistantRanges = []
                            self.outputRanges = []
                            self.errorRanges = []
                            self.hasCommands = !built.1.isEmpty
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
                        let t = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: mode)
                        await MainActor.run {
                            self.transcript = t
                            self.commandRanges = []
                            self.userRanges = []
                            self.assistantRanges = []
                            self.outputRanges = []
                            self.errorRanges = []
                            self.hasCommands = session.events.contains { $0.kind == .tool_call }
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
            if mode == .terminal && shouldColorize {
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
                transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: mode)
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
            if mode == .terminal && shouldColorize {
                let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
                transcript = built.0
                commandRanges = built.1
                userRanges = built.2
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                hasCommands = !built.1.isEmpty
                findAdditionalRanges()
            } else {
                transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: mode)
                commandRanges = []
                userRanges = []
                assistantRanges = []
                outputRanges = []
                errorRanges = []
                hasCommands = session.events.contains { $0.kind == .tool_call }
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
    let appAppearanceRaw: String
    let colorScheme: ColorScheme

    class Coordinator {
        var lastWidth: CGFloat = 0
        var lastPaintedHighlights: [NSRange] = []
        var lastPaintedIndex: Int = -1
        var lastAppearanceRaw: String = ""
        var lastColorScheme: ColorScheme?
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
                applySyntaxColors(tv)
                context.coordinator.lastPaintedHighlights = []
            }

            // Reapply colors when appearance changes (dark/light mode switch)
            if appearanceChanged || schemeChanged {
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

        // Command colorization (foreground) – orange for high distinction
        if !commandRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseOrange = NSColor.systemOrange
            let orange: NSColor = {
                if isDark || increaseContrast { return baseOrange }
                return baseOrange.withAlphaComponent(0.95)
            }()
            for r in commandRanges {
                if NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: orange, range: r)
                }
            }
        }
        // User input colorization (blue)
        if !userRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseBlue = NSColor.systemBlue
            let blue: NSColor = {
                if isDark || increaseContrast { return baseBlue }
                return baseBlue.withAlphaComponent(0.9)
            }()
            for r in userRanges {
                if NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: blue, range: r)
                }
            }
        }
        // Assistant response colorization (subtle gray - less prominent)
        if !assistantRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseGray = NSColor.secondaryLabelColor
            let gray: NSColor = {
                if isDark || increaseContrast { return baseGray }
                return baseGray.withAlphaComponent(0.8)
            }()
            for r in assistantRanges {
                if NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: gray, range: r)
                }
            }
        }
        // Tool output colorization (teal/cyan family for contrast with orange)
        if !outputRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseTeal = NSColor.systemTeal
            let teal: NSColor = {
                if isDark || increaseContrast { return baseTeal }
                return baseTeal.withAlphaComponent(0.90)
            }()
            for r in outputRanges {
                if NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: teal, range: r)
                }
            }
        }
        // Error colorization (red)
        if !errorRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseRed = NSColor.systemRed
            let red: NSColor = {
                if isDark || increaseContrast { return baseRed }
                return baseRed.withAlphaComponent(0.9)
            }()
            for r in errorRanges {
                if NSMaxRange(r) <= full.length {
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
                    let pretty = PrettyJSON.prettyPrinted("[" + s.events.map { $0.rawJSON }.joined(separator: ",") + "]")
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
