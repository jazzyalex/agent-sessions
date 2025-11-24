import SwiftUI
import AppKit

/// Terminal-style session view with filters, optional gutter, and legend toggles.
struct SessionTerminalView: View {
    let session: Session
    let findQuery: String
    let findToken: Int
    let findDirection: Int
    let findReset: Bool
    @Binding var externalMatchCount: Int
    @Binding var externalCurrentMatchIndex: Int
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13

    @State private var lines: [TerminalLine] = []

    enum RoleToggle: CaseIterable {
        case user
        case assistant
        case tools
        case errors
    }

    @AppStorage("TerminalRoleToggles") private var roleToggleRaw: String = "user,assistant,tools,errors"
    @State private var activeRoles: Set<RoleToggle> = Set(RoleToggle.allCases)

    // Line indices for navigation
    @State private var userLineIndices: [Int] = []
    @State private var toolLineIndices: [Int] = []
    @State private var errorLineIndices: [Int] = []

    // Local find state
    @State private var matchingLineIDs: [Int] = []
    @State private var matchIDSet: Set<Int> = []
    @State private var currentMatchLineID: Int? = nil

    // Derived agent label for legend chips (Codex / Claude / Gemini)
    private var agentLegendLabel: String {
        switch session.source {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    private var filteredLines: [TerminalLine] {
        guard !activeRoles.isEmpty else { return lines }
        return lines.filter { line in
            switch line.role {
            case .user:
                return activeRoles.contains(.user)
            case .assistant:
                return activeRoles.contains(.assistant)
            case .toolInput, .toolOutput:
                return activeRoles.contains(.tools)
            case .error:
                return activeRoles.contains(.errors)
            case .meta:
                return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            loadRoleToggles()
            rebuildLines()
        }
        .onChange(of: session.events.count) { _, _ in
            rebuildLines()
        }
    }

    private var toolbar: some View {
        HStack {
            // Left: All + role toggles (legend chips act as toggles)
            HStack(spacing: 6) {
                Button(action: {
                    activeRoles = Set(RoleToggle.allCases)
                    persistRoleToggles()
                }) {
                    Text("All")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(activeRoles.count == RoleToggle.allCases.count ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.borderless)

                legendToggle(color: .blue, label: "User", role: .user)
                legendToggle(color: .green, label: agentLegendLabel, role: .assistant)
                legendToggle(color: .teal, label: "Tools", role: .tools)
                legendToggle(color: .red, label: "Errors", role: .errors)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var content: some View {
        GeometryReader { outerGeo in
            HStack(spacing: 8) {
                TerminalTextScrollView(
                    lines: filteredLines,
                    fontSize: CGFloat(transcriptFontSize),
                    matchIDs: matchIDSet,
                    currentMatchLineID: currentMatchLineID
                )
                .onChange(of: findToken) { _, _ in
                    handleFindRequest()
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func rebuildLines() {
        let built = TerminalBuilder.buildLines(for: session, showMeta: false)
        lines = built

        userLineIndices = built.enumerated().compactMap { idx, line in
            line.role == .user ? idx : nil
        }
        toolLineIndices = built.enumerated().compactMap { idx, line in
            (line.role == .toolInput || line.role == .toolOutput) ? idx : nil
        }
        errorLineIndices = built.enumerated().compactMap { idx, line in
            line.role == .error ? idx : nil
        }

        // Reset local find state when rebuilding.
        matchingLineIDs = []
        matchIDSet = []
        currentMatchLineID = nil
    }

    private func loadRoleToggles() {
        let parts = roleToggleRaw.split(separator: ",").map { String($0) }
        var roles: Set<RoleToggle> = []
        for p in parts {
            switch p {
            case "user": roles.insert(.user)
            case "assistant": roles.insert(.assistant)
            case "tools": roles.insert(.tools)
            case "errors": roles.insert(.errors)
            default: break
            }
        }
        if roles.isEmpty { roles = Set(RoleToggle.allCases) }
        activeRoles = roles
    }

    private func persistRoleToggles() {
        let parts = activeRoles.map { role -> String in
            switch role {
            case .user: return "user"
            case .assistant: return "assistant"
            case .tools: return "tools"
            case .errors: return "errors"
            }
        }
        roleToggleRaw = parts.joined(separator: ",")
    }

    private func legendToggle(color: Color, label: String, role: RoleToggle) -> some View {
        let isOn = activeRoles.contains(role)
        return Button(action: {
            if isOn {
                activeRoles.remove(role)
            } else {
                activeRoles.insert(role)
            }
            persistRoleToggles()
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color.opacity(isOn ? 1.0 : 0.3))
                    .frame(width: 8, height: 8)
                Text(label)
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? color.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.borderless)
    }

    /// Execute a find request driven by the unified toolbar.
    private func handleFindRequest() {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matchingLineIDs = []
            matchIDSet = []
            currentMatchLineID = nil
            externalMatchCount = 0
            externalCurrentMatchIndex = 0
            return
        }

        // Recompute matches over the currently filtered lines.
        let lowerQuery = query.lowercased()
        var ids: [Int] = []
        for line in filteredLines {
            if line.text.range(of: lowerQuery, options: [.caseInsensitive]) != nil {
                ids.append(line.id)
            }
        }
        matchingLineIDs = ids
        matchIDSet = Set(ids)
        externalMatchCount = ids.count

        guard !ids.isEmpty else {
            currentMatchLineID = nil
            externalCurrentMatchIndex = 0
            return
        }

        // Determine which match to select.
        if findReset {
            externalCurrentMatchIndex = 0
        } else {
            var nextIndex = externalCurrentMatchIndex + (findDirection >= 0 ? 1 : -1)
            if nextIndex < 0 {
                nextIndex = ids.count - 1
            } else if nextIndex >= ids.count {
                nextIndex = 0
            }
            externalCurrentMatchIndex = nextIndex
        }

        let clampedIndex = min(max(externalCurrentMatchIndex, 0), ids.count - 1)
        let lineID = ids[clampedIndex]
        currentMatchLineID = lineID
    }
}

// MARK: - Line view

private struct TerminalLineView: View {
    let line: TerminalLine
    let isMatch: Bool
    let isCurrentMatch: Bool
    let fontSize: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            prefixView
            Text(line.text)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundColor(foregroundColor)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(background)
        .cornerRadius(4)
    }

    @ViewBuilder
    private var prefixView: some View {
        switch line.role {
        case .user:
            Text(">")
                .foregroundColor(.blue.opacity(0.7))
                .allowsHitTesting(false)
        case .toolInput:
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundColor(.teal.opacity(0.8))
                .allowsHitTesting(false)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(.red.opacity(0.9))
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private var background: Color {
        var base: Color
        switch line.role {
        case .user:
            base = Color.blue.opacity(0.18)
        case .assistant:
            base = Color.green.opacity(0.18)
        case .toolInput:
            base = Color.indigo.opacity(0.24)
        case .toolOutput:
            base = Color.green.opacity(0.16)
        case .error:
            base = Color.red.opacity(0.55)
        case .meta:
            base = .clear
        }

        if isCurrentMatch {
            return Color.yellow.opacity(0.5)
        } else if isMatch {
            return base.opacity(0.9)
        } else {
            return base
        }
    }

    private var foregroundColor: Color {
        switch line.role {
        case .meta:
            return .secondary
        default:
            return .primary
        }
    }
}

// MARK: - NSTextView-backed selectable terminal renderer

private struct TerminalTextScrollView: NSViewRepresentable {
    let lines: [TerminalLine]
    let fontSize: CGFloat
    let matchIDs: Set<Int>
    let currentMatchLineID: Int?

    class Coordinator {
        var lineRanges: [Int: NSRange] = [:]
        var lastLinesSignature: Int = 0
        var lastMatchSignature: Int = 0
        var lastFontSize: CGFloat = 0
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
        textView.usesFindPanel = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.backgroundColor = NSColor.textBackgroundColor

        scroll.documentView = textView

        applyContent(to: textView, context: context)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }

        let lineSig = signature(for: lines)
        let matchSig = signature(for: Array(matchIDs))
        let fontChanged = abs((context.coordinator.lastFontSize) - fontSize) > 0.1
        let needsReload = lineSig != context.coordinator.lastLinesSignature || matchSig != context.coordinator.lastMatchSignature || fontChanged

        if needsReload {
            applyContent(to: tv, context: context)
            context.coordinator.lastLinesSignature = lineSig
            context.coordinator.lastMatchSignature = matchSig
            context.coordinator.lastFontSize = fontSize
        }

        if let target = currentMatchLineID, let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
        }
    }

    private func applyContent(to textView: NSTextView, context: Context) {
        let (attr, ranges) = buildAttributedString()
        context.coordinator.lineRanges = ranges
        textView.textStorage?.setAttributedString(attr)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Ensure container tracks width
        let width = max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    private func buildAttributedString() -> (NSAttributedString, [Int: NSRange]) {
        let attr = NSMutableAttributedString()
        var ranges: [Int: NSRange] = [:]

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping

        for (idx, line) in lines.enumerated() {
            let text = line.text
            let lineString = idx == lines.count - 1 ? text : text + "\n"
            let ns = lineString as NSString
            let range = NSRange(location: attr.length, length: ns.length)

            let colors = colorsForRole(line.role)
            let isCurrent = (line.id == currentMatchLineID)
            let isMatch = matchIDs.contains(line.id)

            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: colors.foreground,
                .paragraphStyle: paragraph
            ]

            if isCurrent {
                attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.5)
            } else if isMatch {
                attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.25)
            } else if let bg = colors.background {
                attributes[.backgroundColor] = bg
            }

            attr.append(NSAttributedString(string: lineString, attributes: attributes))
            ranges[line.id] = range
        }

        return (attr, ranges)
    }

    private func colorsForRole(_ role: TerminalLineRole) -> (foreground: NSColor, background: NSColor?) {
        switch role {
        case .user:
            return (NSColor.labelColor, NSColor.systemBlue.withAlphaComponent(0.18))
        case .assistant:
            return (NSColor.labelColor, NSColor.systemGreen.withAlphaComponent(0.18))
        case .toolInput:
            return (NSColor.labelColor, NSColor.systemIndigo.withAlphaComponent(0.24))
        case .toolOutput:
            return (NSColor.labelColor, NSColor.systemGreen.withAlphaComponent(0.16))
        case .error:
            return (NSColor.labelColor, NSColor.systemRed.withAlphaComponent(0.55))
        case .meta:
            return (NSColor.secondaryLabelColor, nil)
        }
    }

    private func signature(for lines: [TerminalLine]) -> Int {
        var hasher = Hasher()
        hasher.combine(lines.count)
        if let first = lines.first { hasher.combine(first.id); hasher.combine(first.text.count) }
        if let last = lines.last { hasher.combine(last.id); hasher.combine(last.text.count) }
        let totalChars = lines.reduce(0) { $0 + $1.text.count }
        hasher.combine(totalChars)
        return hasher.finalize()
    }

    private func signature(for ids: [Int]) -> Int {
        var hasher = Hasher()
        hasher.combine(ids.count)
        if let first = ids.first { hasher.combine(first) }
        if let last = ids.last { hasher.combine(last) }
        return hasher.finalize()
    }
}
