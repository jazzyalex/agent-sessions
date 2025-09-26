import SwiftUI
import AppKit

struct TranscriptPlainView: View {
    @EnvironmentObject var indexer: SessionIndexer
    let sessionID: String?

    // Plain transcript buffer
    @State private var transcript: String = ""

    // Find
    @State private var findText: String = ""
    @State private var findMatches: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = 0
    @FocusState private var findFocused: Bool
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
            Divider()
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
        }
        .onAppear { syncPrefs(); rebuild() }
        .onChange(of: sessionID) { _, _ in rebuild() }
        .onChange(of: indexer.sessions) { _, _ in rebuild() }
        .onChange(of: indexer.query) { _, _ in rebuild() }
        .onChange(of: renderModeRaw) { _, _ in rebuild() }
        .onReceive(indexer.$requestCopyPlain) { _ in copyAll() }
        .onReceive(indexer.$requestTranscriptFindFocus) { _ in findFocused = true }
        .sheet(isPresented: $showRawSheet) { WholeSessionRawPrettySheet(session: currentSession) }
        .onChange(of: indexer.requestOpenRawSheet) { _, newVal in
            if newVal {
                showRawSheet = true
                indexer.requestOpenRawSheet = false
            }
        }
    }

    private var currentSession: Session? {
        guard let sid = sessionID else { return nil }
        if let s = indexer.sessions.first(where: { $0.id == sid }) { return s }
        return indexer.allSessions.first(where: { $0.id == sid })
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Find controls group
            HStack(spacing: 4) {
                Button(action: { performFind(resetIndex: true) }) {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Find")

                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 180)
                    .focused($findFocused)
                    .onSubmit { performFind(resetIndex: true) }

                Button(action: { performFind(resetIndex: false, direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Previous match")
                .disabled(findMatches.isEmpty)

                Button(action: { performFind(resetIndex: false, direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Next match")
                .disabled(findMatches.isEmpty)

                if !findText.isEmpty {
                    Text("\(findMatches.isEmpty ? 0 : currentMatchIndex + 1)/\(findMatches.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minWidth: 35)
                }

                Divider().frame(height: 20)

                HStack(spacing: 2) {
                    Button(action: { adjustFont(-1) }) {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Make text smaller")
                    .help("Smaller (Cmd-)")

                    Button(action: { adjustFont(1) }) {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Make text bigger")
                    .help("Bigger (Cmd+=)")
                }

                Button("Copy") { copyAll() }
                    .buttonStyle(.borderless)
                    .help("Copy entire transcript")
            }

            Divider().frame(height: 20)

            Spacer(minLength: 8)

            // View controls group
            HStack(spacing: 6) {
                // ID button (copy full Codex UUID), placed before Transcript mode picker
                if let short = codexShortID {
                    Button("ID \(short)") {
                        copyCodexSessionID()
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Codex session ID to clipboard")
                    .popover(isPresented: $showIDCopiedPopover, arrowEdge: .bottom) {
                        Text("Session ID copied")
                            .font(.caption)
                            .padding(8)
                    }
                } else {
                    Button("ID —") {}
                        .buttonStyle(.borderless)
                        .disabled(true)
                        .help("No Codex session ID available")
                }

                Picker("View Style", selection: $renderModeRaw) {
                    Text("Transcript").tag(TranscriptRenderMode.normal.rawValue)
                    Text("Terminal").tag(TranscriptRenderMode.terminal.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 44)
    }

    private func syncPrefs() {
        // Defaults are off; nothing to sync
    }

    private func rebuild() {
        guard let s = currentSession else { transcript = ""; return }
        let filters: TranscriptFilters = .current(showTimestamps: showTimestamps, showMeta: false)
        let mode = TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal
        if mode == .terminal && shouldColorize {
            let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: s, filters: filters)
            transcript = built.0
            commandRanges = built.1
            userRanges = built.2
            // Still need to find assistant, output, and error ranges for terminal mode
            assistantRanges = []
            outputRanges = []
            errorRanges = []
            findAdditionalRanges()
        } else {
            transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: filters, mode: mode)
            commandRanges = []
            // Build additional ranges for colorization
            if shouldColorize {
                userRanges = []
                assistantRanges = []
                outputRanges = []
                errorRanges = []

                // Find user input ranges in normal mode
                let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
                var cursor = 0

                for line in lines {
                    let s = String(line)
                    var lineStr = s
                    var timestampOffset = 0
                    if lineStr.count >= 9, lineStr[lineStr.index(lineStr.startIndex, offsetBy: 2)] == ":" {
                        if let space = lineStr.firstIndex(of: " ") {
                            timestampOffset = lineStr.distance(from: lineStr.startIndex, to: lineStr.index(after: space))
                            lineStr = String(lineStr[lineStr.index(after: space)...])
                        }
                    }

                    // User input: "> text"
                    if lineStr.hasPrefix("> ") {
                        let start = cursor + timestampOffset + 2
                        let len = (s as NSString).length - timestampOffset - 2
                        if len > 0 { userRanges.append(NSRange(location: start, length: len)) }
                    }

                    cursor += (s as NSString).length + 1
                }

                // Find other content types
                findAdditionalRanges()
            } else {
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
    }

    private func performFind(resetIndex: Bool, direction: Int = 1) {
        let q = findText
        guard !q.isEmpty else {
            findMatches = []
            currentMatchIndex = 0
            highlightRanges = []
            return
        }

        // First search in the rendered transcript
        let lowerText = transcript.lowercased()
        let lowerQ = q.lowercased()
        var matches: [Range<String.Index>] = []
        var searchStart = lowerText.startIndex
        while let r = lowerText.range(of: lowerQ, range: searchStart..<lowerText.endIndex) {
            let origStart = transcript.index(transcript.startIndex, offsetBy: lowerText.distance(from: lowerText.startIndex, to: r.lowerBound))
            let origEnd = transcript.index(origStart, offsetBy: lowerQ.count)
            matches.append(origStart..<origEnd)
            searchStart = r.upperBound
        }

        // If no matches in transcript, check if the term exists in raw session data
        // to provide feedback consistent with global search
        if matches.isEmpty, let session = currentSession {
            let hasMatchInRawData = session.events.contains { e in
                if let t = e.text, t.localizedCaseInsensitiveContains(q) { return true }
                if let ti = e.toolInput, ti.localizedCaseInsensitiveContains(q) { return true }
                if let to = e.toolOutput, to.localizedCaseInsensitiveContains(q) { return true }
                if e.rawJSON.localizedCaseInsensitiveContains(q) { return true }
                return false
            }

            // If found in raw data but not in transcript, show a helpful message
            if hasMatchInRawData {
                // Insert a note in the transcript about hidden matches
                let noteText = "\n[Note: '\(q)' found in raw session data but not in rendered transcript. Use Raw JSON view to see all content.]\n"
                transcript += noteText

                // Find the note in the updated transcript
                let updatedLowerText = transcript.lowercased()
                if let noteRange = updatedLowerText.range(of: "note:") {
                    let origStart = transcript.index(transcript.startIndex, offsetBy: updatedLowerText.distance(from: updatedLowerText.startIndex, to: noteRange.lowerBound))
                    let origEnd = transcript.index(origStart, offsetBy: noteText.count - 2) // Exclude newlines
                    matches.append(origStart..<origEnd)
                }
            }
        }

        findMatches = matches
        // Build NSRanges for temporary highlight attributes
        var nsRanges: [NSRange] = []
        for r in matches {
            if let nsr = NSRange(r, in: transcript) as NSRange? { nsRanges.append(nsr) }
        }
        highlightRanges = nsRanges
        if resetIndex { currentMatchIndex = matches.isEmpty ? 0 : 0 }
        else if !matches.isEmpty {
            currentMatchIndex = (currentMatchIndex + direction + matches.count) % matches.count
        }
        // Note: We intentionally avoid styling/highlights per spec (plain text only)
        updateSelectionToCurrentMatch()
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private var codexShortID: String? {
        guard let sid = currentSession?.codexFilenameUUID, !sid.isEmpty else { return nil }
        return String(sid.prefix(6))
    }

    private func copyCodexSessionID() {
        guard let sid = currentSession?.codexFilenameUUID, !sid.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sid, forType: .string)
        showIDCopiedPopover = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showIDCopiedPopover = false
        }
    }

    private func findAdditionalRanges() {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        var cursor = 0

        for line in lines {
            let s = String(line)
            // Skip timestamp prefix if present (HH:MM:SS format)
            var lineStr = s
            var timestampOffset = 0
            if lineStr.count >= 9, lineStr[lineStr.index(lineStr.startIndex, offsetBy: 2)] == ":" {
                if let space = lineStr.firstIndex(of: " ") {
                    timestampOffset = lineStr.distance(from: lineStr.startIndex, to: lineStr.index(after: space))
                    lineStr = String(lineStr[lineStr.index(after: space)...])
                }
            }

            // Tool output: "⟪out⟫ text"
            if lineStr.hasPrefix("⟪out⟫ ") {
                let start = cursor + timestampOffset
                let len = (s as NSString).length - timestampOffset
                if len > 0 { outputRanges.append(NSRange(location: start, length: len)) }
            }
            // Errors: "! error text"
            else if lineStr.hasPrefix("! error ") {
                let start = cursor + timestampOffset
                let len = (s as NSString).length - timestampOffset
                if len > 0 { errorRanges.append(NSRange(location: start, length: len)) }
            }
            // Assistant responses: everything else that's not empty and not a known prefix
            else if !lineStr.isEmpty && !lineStr.hasPrefix("⟪") && !lineStr.hasPrefix("›") && !lineStr.hasPrefix("!") && !lineStr.hasPrefix("> ") && !lineStr.hasPrefix("bash ") && !lineStr.hasPrefix("cd ") {
                let start = cursor + timestampOffset
                let len = (s as NSString).length - timestampOffset
                if len > 0 { assistantRanges.append(NSRange(location: start, length: len)) }
            }

            cursor += (s as NSString).length + 1
        }
    }
}

// MARK: - NSViewRepresentable plain text, selectable, scrollable

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
        textView.backgroundColor = .clear
        textView.string = text
        applyHighlights(textView)

        scroll.documentView = textView
        if let sel = selection { textView.setSelectedRange(sel); textView.scrollRangeToVisible(sel) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? NSTextView {
            if tv.string != text { tv.string = text }
            if let font = tv.font, abs(font.pointSize - fontSize) > 0.5 {
                tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }
            let width = max(1, nsView.contentSize.width)
            tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            tv.setFrameSize(NSSize(width: width, height: tv.frame.size.height))
            if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }
            if let sel = selection {
                tv.setSelectedRange(sel)
                tv.scrollRangeToVisible(sel)
            }
            applyHighlights(tv)
        }
    }

    private func applyHighlights(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
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
                    lm.addTemporaryAttribute(.foregroundColor, value: green, forCharacterRange: r)
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
                    lm.addTemporaryAttribute(.foregroundColor, value: blue, forCharacterRange: r)
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
                    lm.addTemporaryAttribute(.foregroundColor, value: gray, forCharacterRange: r)
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
                    lm.addTemporaryAttribute(.foregroundColor, value: dimmedGreen, forCharacterRange: r)
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
                    lm.addTemporaryAttribute(.foregroundColor, value: red, forCharacterRange: r)
                }
            }
        }
        // Find match background highlights
        guard !highlights.isEmpty else { return }
        // Colors that read well in both light and dark appearances
        let matchBG = NSColor.systemYellow.withAlphaComponent(0.35)
        let currentBG = NSColor.systemOrange.withAlphaComponent(0.55)
        for (i, r) in highlights.enumerated() {
            if NSMaxRange(r) <= full.length {
                let color = (i == currentIndex) ? currentBG : matchBG
                lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r)
            }
        }
    }
}

// MARK: - Find selection helper

private extension TranscriptPlainView {
    func updateSelectionToCurrentMatch() {
        guard !findMatches.isEmpty else { selectedNSRange = nil; return }
        let range = findMatches[min(currentMatchIndex, findMatches.count - 1)]
        if let nsRange = NSRange(range, in: transcript) as NSRange? { selectedNSRange = nsRange }
    }
    func adjustFont(_ delta: Double) {
        transcriptFontSize = max(9, min(30, transcriptFontSize + delta))
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
