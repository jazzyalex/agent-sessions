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
    @State private var findRevision: Int = 0  // Increment to force view update
    @FocusState private var findFocused: Bool
    @State private var allowFindFocus: Bool = false
    @State private var highlightRanges: [NSRange] = []
    @State private var commandRanges: [NSRange] = []
    @State private var userRanges: [NSRange] = []
    @State private var assistantRanges: [NSRange] = []
    @State private var outputRanges: [NSRange] = []
    @State private var errorRanges: [NSRange] = []

    // Toggles (view-scoped)
    @State private var showTimestamps: Bool = false
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.normal.rawValue

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
                        errorRanges: shouldColorize ? errorRanges : []
                    )
                    .id(findRevision)  // Force view update when navigating between matches

                    if indexer.isLoadingSession && indexer.loadingSessionID == id {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading session...")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
                        .cornerRadius(12)
                        .shadow(radius: 8)
                    }
                }
            }
            .onAppear { rebuild(session: session) }
            .onChange(of: id) { _, _ in rebuild(session: session) }
            .onChange(of: renderModeRaw) { _, _ in rebuild(session: session) }
            .onChange(of: session.events.count) { _, _ in rebuild(session: session) }
            .onReceive(indexer.requestCopyPlainPublisher) { _ in copyAll() }
            .onReceive(indexer.requestTranscriptFindFocusPublisher) { _ in if allowFindFocus { findFocused = true } }
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
            Button(action: { allowFindFocus = true; findFocused = true }) { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

            // Find controls group
            HStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                    TextField("Find", text: $findText)
                        .textFieldStyle(.plain)
                        .focused($findFocused)
                        .focusable(allowFindFocus)
                        .onSubmit { performFind(resetIndex: true) }
                        .help("Enter text to highlight matches in the session")
                        .frame(minWidth: 180)
                    if !findText.isEmpty {
                        Button(action: { findText = ""; performFind(resetIndex: true) }) {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(findFocused ? Color.blue.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: findFocused ? 2 : 1)
                )
                .onTapGesture { allowFindFocus = true; findFocused = true }
                .onAppear { allowFindFocus = true }

                Button(action: { performFind(resetIndex: false, direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Jump to the previous match")

                Button(action: { performFind(resetIndex: false, direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Jump to the next match")

                Text(findStatus())
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .leading)
            }
            .padding(.leading, 8)

            Spacer(minLength: 8)

            Divider().frame(height: 20)

            HStack(spacing: 2) {
                Button(action: { adjustFont(-1) }) {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Decrease font size")

                Button(action: { adjustFont(1) }) {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Increase font size")
            }

            Button("Copy") { copyAll() }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Copy entire transcript to clipboard")
                .keyboardShortcut("c", modifiers: [.command, .option])

            Divider().frame(height: 20)

            // View controls group
            HStack(spacing: 6) {
                // Session ID (copy full ID from session)
                if let short = extractShortID(for: session) {
                    Button("ID \(short)") {
                        copySessionID(for: session)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("Copy full session ID to clipboard")
                    .popover(isPresented: $showIDCopiedPopover, arrowEdge: .bottom) {
                        Text("Copied!")
                            .padding(8)
                            .font(.system(size: 12))
                    }
                } else {
                    Button("ID —") {}
                        .buttonStyle(.borderless)
                        .disabled(true)
                        .help("No \(sessionIDLabel) session ID available")
                }

                Picker("View Style", selection: $renderModeRaw) {
                    Text("Transcript")
                        .tag(TranscriptRenderMode.normal.rawValue)
                        .help("Plain text view with roles and tool labels; no semantic colorization")
                    Text("Terminal")
                        .tag(TranscriptRenderMode.terminal.rawValue)
                        .help("Terminal view that expands shell calls into commands and color‑highlights commands (green), user input (blue), outputs (dim green), and errors (red)")
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
                .focusable(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 44)
    }

    private func rebuild(session: Session) {
        let filters: TranscriptFilters = .current(showTimestamps: showTimestamps, showMeta: false)
        let mode = TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal

        if enableCaching {
            // Memoization key: session identity, event count, render mode, and timestamp setting
            let key = "\(session.id)|\(session.events.count)|\(renderModeRaw)|\(showTimestamps ? 1 : 0)"
            if lastBuildKey == key { return }

            if mode == .terminal && shouldColorize {
                // Try cache first (text + terminal ranges)
                if let cached = transcriptCache[key] {
                    transcript = cached
                    commandRanges = terminalCommandRangesCache[key] ?? []
                    userRanges = terminalUserRangesCache[key] ?? []
                    assistantRanges = []
                    outputRanges = []
                    errorRanges = []
                    findAdditionalRanges()
                    lastBuildKey = key
                } else {
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
                }
            } else {
                if let cached = transcriptCache[key] {
                    transcript = cached
                    commandRanges = []
                    userRanges = []
                    assistantRanges = []
                    outputRanges = []
                    errorRanges = []
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
                findAdditionalRanges()
            } else {
                transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: mode)
                commandRanges = []
                userRanges = []
                assistantRanges = []
                outputRanges = []
                errorRanges = []
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

    private func performFind(resetIndex: Bool, direction: Int = 1) {
        let q = findText
        guard !q.isEmpty else {
            findMatches = []
            currentMatchIndex = 0
            highlightRanges = []
            return
        }
        let lower = transcript.lowercased()
        let lowerQ = q.lowercased()
        var matches: [Range<String.Index>] = []
        var searchStart = lower.startIndex
        while let r = lower.range(of: lowerQ, range: searchStart..<lower.endIndex) {
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
            highlightRanges = matches.map { NSRange($0, in: transcript) }
            updateSelectionToCurrentMatch()
            // Increment revision to force immediate view update with new highlights
            findRevision += 1
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
            if lineStr.hasPrefix("assistant ∎ ") {
                let r = NSRange(location: pos, length: len)
                asst.append(r)
            } else if lineStr.hasPrefix("output ≡ ") || lineStr.hasPrefix("  | ") {
                let r = NSRange(location: pos, length: len)
                out.append(r)
            } else if lineStr.hasPrefix("error ⚠ ") {
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

    class Coordinator { var lastWidth: CGFloat = 0 }
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

        // Apply dimming effect when Find is active (like Apple Notes)
        if !highlights.isEmpty {
            textView.backgroundColor = NSColor.black.withAlphaComponent(0.08)
        } else {
            textView.backgroundColor = .clear
        }

        textView.string = text
        applyHighlights(textView)

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
            if tv.string != text { tv.string = text }
            if let font = tv.font, abs(font.pointSize - fontSize) > 0.5 {
                tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }

            // Apply/remove dimming effect based on Find state (like Apple Notes)
            if !highlights.isEmpty {
                tv.backgroundColor = NSColor.black.withAlphaComponent(0.08)
            } else {
                tv.backgroundColor = .clear
            }

            let width = max(1, nsView.contentSize.width)
            tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            tv.setFrameSize(NSSize(width: width, height: tv.frame.size.height))
            if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }

            // Scroll to current match if any
            if let sel = selection {
                tv.scrollRangeToVisible(sel)
                // Clear selection immediately to avoid blue highlight - we use yellow/white backgrounds instead
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }

            applyHighlights(tv)
        }
    }

    private func applyHighlights(_ tv: NSTextView) {
        guard let textStorage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)

        // Remove all previous attributes (use textStorage for persistent attributes)
        textStorage.removeAttribute(.backgroundColor, range: full)
        textStorage.removeAttribute(.foregroundColor, range: full)

        // Command colorization (foreground)
        if !commandRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseGreen = NSColor.systemGreen
            let green: NSColor = {
                if isDark || increaseContrast { return baseGreen }
                return baseGreen.withAlphaComponent(0.88)
            }()
            for r in commandRanges {
                if NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: green, range: r)
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
        // Tool output colorization (dimmed green)
        if !outputRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseGreen = NSColor.systemGreen
            let dimmedGreen: NSColor = {
                if isDark || increaseContrast { return baseGreen.withAlphaComponent(0.6) }
                return baseGreen.withAlphaComponent(0.5)
            }()
            for r in outputRanges {
                if NSMaxRange(r) <= full.length {
                    textStorage.addAttribute(.foregroundColor, value: dimmedGreen, range: r)
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

        // Find match highlights - apply LAST to override all colorization and ensure visibility
        // Apple Notes style: yellow for current match, white for others
        // Use textStorage attributes (not temporary) so they persist regardless of focus
        if !highlights.isEmpty {
            let currentBG = NSColor(deviceRed: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)  // Yellow (like Apple Notes)
            let otherBG = NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.9)   // White (more opaque for visibility)
            let matchFG = NSColor.black  // Black text for contrast
            for (i, r) in highlights.enumerated() {
                if NSMaxRange(r) <= full.length {
                    let bg = (i == currentIndex) ? currentBG : otherBG
                    // Apply attributes to textStorage for persistent rendering
                    textStorage.addAttribute(.backgroundColor, value: bg, range: r)
                    textStorage.addAttribute(.foregroundColor, value: matchFG, range: r)
                }
            }
        }
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
