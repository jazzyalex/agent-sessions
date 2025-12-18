import SwiftUI
import AppKit
import Foundation

/// Terminal-style session view with filters, optional gutter, and legend toggles.
struct SessionTerminalView: View {
    let session: Session
    let findQuery: String
    let findToken: Int
    let findDirection: Int
    let findReset: Bool
    let jumpToken: Int
    @Binding var externalMatchCount: Int
    @Binding var externalCurrentMatchIndex: Int
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var lines: [TerminalLine] = []

    enum RoleToggle: CaseIterable {
        case user
        case assistant
        case tools
        case errors
    }

    @AppStorage("TerminalRoleToggles") private var roleToggleRaw: String = "user,assistant,tools,errors"
    @State private var activeRoles: Set<RoleToggle> = Set(RoleToggle.allCases)

    // Line identifiers for navigation
    @State private var userLineIndices: [Int] = []
    @State private var assistantLineIndices: [Int] = []
    @State private var toolLineIndices: [Int] = []
    @State private var errorLineIndices: [Int] = []
    @State private var roleNavPositions: [RoleToggle: Int] = [:]

    // Local find state
    @State private var matchingLineIDs: [Int] = []
    @State private var matchIDSet: Set<Int> = []
    @State private var currentMatchLineID: Int? = nil
    @State private var firstPromptLineID: Int? = nil
    @State private var scrollTargetLineID: Int? = nil
    @State private var scrollTargetToken: Int = 0

    // Derived agent label for legend chips (Codex / Claude / Gemini)
    private var agentLegendLabel: String {
        switch session.source {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
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
        .onChange(of: jumpToken) { _, _ in
            jumpToFirstPrompt()
        }
        .onChange(of: session.events.count) { _, _ in
            rebuildLines()
        }
    }

    private var toolbar: some View {
        HStack {
            // Left: All + role toggles (legend chips act as toggles)
            HStack(spacing: 14) {
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

                legendToggle(label: "User", role: .user)
                legendToggle(label: agentLegendLabel, role: .assistant)
                legendToggle(label: "Tools", role: .tools)
                legendToggle(label: "Errors", role: .errors)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            if shouldShowConversationStartControls, let _ = firstPromptLineID {
                Button(action: { jumpToFirstPrompt() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .imageScale(.small)
                        Text("First prompt")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Jump to the first user prompt after </INSTRUCTIONS>")
            }
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
                    currentMatchLineID: currentMatchLineID,
                    scrollTargetLineID: scrollTargetLineID,
                    scrollTargetToken: scrollTargetToken,
                    colorScheme: colorScheme,
                    monochrome: stripMonochrome
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
        let skip = skipAgentsPreambleEnabled()
        let (decorated, promptID) = applyConversationStartDividerIfNeeded(lines: built, enabled: skip)
        lines = decorated
        firstPromptLineID = promptID

        // Collapse multi-line blocks into single navigable/message entries per role.
        var firstLineForBlock: [Int: Int] = [:]       // blockIndex -> first line id
        var roleForBlock: [Int: TerminalLineRole] = [:]

        for line in decorated {
            guard let blockIndex = line.blockIndex else { continue }
            if firstLineForBlock[blockIndex] == nil {
                firstLineForBlock[blockIndex] = line.id
                roleForBlock[blockIndex] = line.role
            }
        }

        func messageIDs(for roleMatch: (TerminalLineRole) -> Bool) -> [Int] {
            firstLineForBlock.compactMap { blockIndex, lineID in
                guard let role = roleForBlock[blockIndex], roleMatch(role) else { return nil }
                return lineID
            }
            .sorted()
        }

        userLineIndices = messageIDs { $0 == .user }
        assistantLineIndices = messageIDs { $0 == .assistant }
        toolLineIndices = messageIDs { role in
            role == .toolInput || role == .toolOutput
        }
        errorLineIndices = messageIDs { $0 == .error }

        // Reset local find state when rebuilding.
        matchingLineIDs = []
        matchIDSet = []
        currentMatchLineID = nil
        roleNavPositions = [:]

        if skip, findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            jumpToFirstPrompt()
        }
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

    private func legendToggle(label: String, role: RoleToggle) -> some View {
        let isOn = activeRoles.contains(role)
        let swatch = TerminalRolePalette.swiftUI(role: TerminalRolePalette.role(for: role), scheme: colorScheme, monochrome: stripMonochrome)
        let indices = indicesForRole(role)
        let hasLines = !indices.isEmpty
        let navDisabled = !isOn || !hasLines
        let showCount = true

        return HStack(spacing: 6) {
            Button(action: {
                if isOn {
                    activeRoles.remove(role)
                } else {
                    activeRoles.insert(role)
                }
                persistRoleToggles()
            }) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(swatch.accent.opacity(isOn ? 1.0 : 0.35))
                        .frame(width: 8, height: 8)
                    Text(label)
                        .foregroundStyle(isOn ? .primary : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOn ? (swatch.background ?? swatch.accent.opacity(0.2)) : Color.clear)
                )
            }
            .buttonStyle(.borderless)

            if showCount {
                let status = navigationStatus(for: role)
                Text("\(formattedCount(status.current))/\(formattedCount(status.total))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        hasLines
                        ? (isOn ? swatch.accent : swatch.accent.opacity(0.55))
                        : Color.secondary.opacity(0.45)
                    )
            }

            HStack(spacing: 2) {
                Button(action: { navigateRole(role, direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PillIconButtonStyle(tint: swatch.accent, disabled: navDisabled))
                .disabled(navDisabled)
                .help(previousHelpText(for: role))

                Button(action: { navigateRole(role, direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PillIconButtonStyle(tint: swatch.accent, disabled: navDisabled))
                .disabled(navDisabled)
                .help(nextHelpText(for: role))
            }
        }
    }

    private func formattedCount(_ count: Int) -> String {
        let clamped = min(max(count, 0), 999_999)
        let base = clamped.formatted(.number.grouping(.automatic))
        if count > 999_999 {
            return base + "+"
        }
        return base
    }

    private func navigationStatus(for role: RoleToggle) -> (current: Int, total: Int) {
        let ids = indicesForRole(role)
        let total = ids.count
        guard total > 0 else { return (0, 0) }
        let sorted = ids.sorted()

        if let stored = roleNavPositions[role], stored >= 0, stored < total {
            return (stored + 1, total)
        }

        if let currentID = currentMatchLineID, let pos = sorted.firstIndex(of: currentID) {
            return (pos + 1, total)
        }

        return (0, total)
    }

    private func indicesForRole(_ role: RoleToggle) -> [Int] {
        switch role {
        case .user:
            return userLineIndices
        case .assistant:
            return assistantLineIndices
        case .tools:
            return toolLineIndices
        case .errors:
            return errorLineIndices
        }
    }

    private func previousHelpText(for role: RoleToggle) -> String {
        switch role {
        case .user: return "Previous user prompt"
        case .assistant: return "Previous agent response"
        case .tools: return "Previous tool call/output"
        case .errors: return "Previous error"
        }
    }

    private func nextHelpText(for role: RoleToggle) -> String {
        switch role {
        case .user: return "Next user prompt"
        case .assistant: return "Next agent response"
        case .tools: return "Next tool call/output"
        case .errors: return "Next error"
        }
    }

    private func navigateRole(_ role: RoleToggle, direction: Int) {
        guard activeRoles.contains(role) else { return }
        let ids = indicesForRole(role)
        guard !ids.isEmpty else { return }

        let sorted = ids.sorted()
        let step = direction >= 0 ? 1 : -1
        let count = sorted.count

        func wrapIndex(_ value: Int) -> Int {
            (value % count + count) % count
        }

        let startIndex: Int
        if let stored = roleNavPositions[role], stored >= 0, stored < count {
            startIndex = stored
        } else if let currentID = currentMatchLineID, let pos = sorted.firstIndex(of: currentID) {
            startIndex = pos
        } else {
            startIndex = direction >= 0 ? 0 : (count - 1)
        }

        let nextIndex = wrapIndex(startIndex + step)
        roleNavPositions[role] = nextIndex
        currentMatchLineID = sorted[nextIndex]
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

    private var shouldShowConversationStartControls: Bool {
        skipAgentsPreambleEnabled() && (firstPromptLineID != nil)
    }

    private func skipAgentsPreambleEnabled() -> Bool {
        let d = UserDefaults.standard
        let key = PreferencesKey.Unified.skipAgentsPreamble
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    private func jumpToFirstPrompt() {
        guard let target = firstPromptLineID else { return }
        scrollTargetLineID = target
        scrollTargetToken &+= 1
    }

    private func applyConversationStartDividerIfNeeded(lines: [TerminalLine], enabled: Bool) -> ([TerminalLine], Int?) {
        guard enabled else { return (lines, nil) }
        let marker = "</INSTRUCTIONS>"
        guard let closeIndex = lines.firstIndex(where: { $0.text.contains(marker) }) else {
            return (lines, nil)
        }
        // Find first non-empty user line after the closing marker.
        var promptIndex: Int? = nil
        var i = closeIndex + 1
        while i < lines.count {
            let line = lines[i]
            if line.role == .user {
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.contains(marker) {
                    promptIndex = i
                    break
                }
            }
            i += 1
        }
        guard let insertAt = promptIndex else { return (lines, nil) }

        // Avoid double insertion.
        if lines.contains(where: { $0.role == .meta && $0.text.contains("Conversation starts here") }) {
            return (lines, insertAt)
        }

        var out: [TerminalLine] = []
        out.reserveCapacity(lines.count + 1)
        for (idx, line) in lines.enumerated() {
            if idx == insertAt {
                out.append(TerminalLine(
                    id: -1,
                    text: "──────── Conversation starts here ────────",
                    role: .meta,
                    eventIndex: nil,
                    blockIndex: nil
                ))
            }
            out.append(line)
        }
        // Reindex IDs to remain stable/incremental.
        out = out.enumerated().map { newIdx, line in
            TerminalLine(
                id: newIdx,
                text: line.text,
                role: line.role,
                eventIndex: line.eventIndex,
                blockIndex: line.blockIndex
            )
        }

        // Prompt line shifted down by +1 due to inserted divider.
        return (out, insertAt + 1)
    }
}

// MARK: - Line view

private struct TerminalLineView: View {
    let line: TerminalLine
    let isMatch: Bool
    let isCurrentMatch: Bool
    let fontSize: Double
    let monochrome: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            prefixView
            Text(line.text)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundColor(swatch.foreground)
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
                .foregroundColor(swatch.accent)
                .allowsHitTesting(false)
        case .toolInput:
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundColor(swatch.accent)
                .allowsHitTesting(false)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(swatch.accent)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private var background: Color {
        if isCurrentMatch {
            return Color.yellow.opacity(0.5)
        } else if isMatch {
            return (swatch.background ?? swatch.accent.opacity(0.22)).opacity(0.95)
        } else {
            return swatch.background ?? Color.clear
        }
    }

    private var swatch: TerminalRolePalette.SwiftUISwatch {
        TerminalRolePalette.swiftUI(role: line.role.paletteRole, scheme: colorScheme, monochrome: monochrome)
    }
}

// MARK: - Button Styles

private struct PillIconButtonStyle: ButtonStyle {
    let tint: Color
    let disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(disabled ? Color.secondary.opacity(0.6) : tint)
            .background(
                Circle()
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(borderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if disabled { return Color.clear }
        if isPressed { return tint.opacity(0.25) }
        return tint.opacity(0.12)
    }

    private func borderColor(isPressed: Bool) -> Color {
        if disabled { return Color.clear }
        return tint.opacity(isPressed ? 0.55 : 0.35)
    }
}

// MARK: - NSTextView-backed selectable terminal renderer

private struct TerminalRolePalette {
    enum Role {
        case user
        case assistant
        case tool
        case error
        case meta
    }

    struct SwiftUISwatch {
        let foreground: Color
        let background: Color?
        let accent: Color
    }

    struct AppKitSwatch {
        let foreground: NSColor
        let background: NSColor?
        let accent: NSColor
    }

    static func role(for toggle: SessionTerminalView.RoleToggle) -> Role {
        switch toggle {
        case .user: return .user
        case .assistant: return .assistant
        case .tools: return .tool
        case .errors: return .error
        }
    }

    static func swiftUI(role: Role, scheme: ColorScheme, monochrome: Bool = false) -> SwiftUISwatch {
        let appKitColors = baseColors(for: role, scheme: scheme, monochrome: monochrome)
        return SwiftUISwatch(
            foreground: Color(nsColor: appKitColors.foreground),
            background: appKitColors.background.map { Color(nsColor: $0) },
            accent: Color(nsColor: appKitColors.accent)
        )
    }

    static func appKit(role: Role, scheme: ColorScheme, monochrome: Bool = false) -> AppKitSwatch {
        baseColors(for: role, scheme: scheme, monochrome: monochrome)
    }

    private static func baseColors(for role: Role, scheme: ColorScheme, monochrome: Bool) -> AppKitSwatch {
        let isDark = (scheme == .dark)

        func tinted(_ color: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
            color.withAlphaComponent(isDark ? dark : light)
        }

        if monochrome {
            // Monochrome mode: use gray shades
            switch role {
            case .user:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.5, alpha: isDark ? 0.20 : 0.12),
                    accent: NSColor(white: 0.5, alpha: 1.0)
                )
            case .assistant:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.4, alpha: isDark ? 0.18 : 0.10),
                    accent: NSColor(white: 0.4, alpha: 1.0)
                )
            case .tool:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.6, alpha: isDark ? 0.22 : 0.14),
                    accent: NSColor(white: 0.6, alpha: 1.0)
                )
            case .error:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.3, alpha: isDark ? 0.30 : 0.20),
                    accent: NSColor(white: 0.3, alpha: 1.0)
                )
            case .meta:
                return AppKitSwatch(
                    foreground: NSColor.secondaryLabelColor,
                    background: nil,
                    accent: NSColor.secondaryLabelColor
                )
            }
        } else {
            // Color mode: original palette
            switch role {
            case .user:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemBlue, light: 0.16, dark: 0.30),
                    accent: NSColor.systemBlue
                )
            case .assistant:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemGreen, light: 0.16, dark: 0.26),
                    accent: NSColor.systemGreen
                )
            case .tool:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemIndigo, light: 0.20, dark: 0.32),
                    accent: NSColor.systemIndigo
                )
            case .error:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemRed, light: 0.28, dark: 0.40),
                    accent: NSColor.systemRed
                )
            case .meta:
                return AppKitSwatch(
                    foreground: NSColor.secondaryLabelColor,
                    background: nil,
                    accent: NSColor.secondaryLabelColor
                )
            }
        }
    }
}

private extension TerminalLineRole {
    var paletteRole: TerminalRolePalette.Role {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .toolInput, .toolOutput: return .tool
        case .error: return .error
        case .meta: return .meta
        }
    }
}

private struct TerminalTextScrollView: NSViewRepresentable {
    let lines: [TerminalLine]
    let fontSize: CGFloat
    let matchIDs: Set<Int>
    let currentMatchLineID: Int?
    let scrollTargetLineID: Int?
    let scrollTargetToken: Int
    let colorScheme: ColorScheme
    let monochrome: Bool

    class Coordinator {
        var lineRanges: [Int: NSRange] = [:]
        var lastLinesSignature: Int = 0
        var lastMatchSignature: Int = 0
        var lastFontSize: CGFloat = 0
        var lastMonochrome: Bool = false
        var lastScrollToken: Int = 0
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
        let monochromeChanged = context.coordinator.lastMonochrome != monochrome
        let needsReload = lineSig != context.coordinator.lastLinesSignature || matchSig != context.coordinator.lastMatchSignature || fontChanged || monochromeChanged

        if needsReload {
            applyContent(to: tv, context: context)
            context.coordinator.lastLinesSignature = lineSig
            context.coordinator.lastMatchSignature = matchSig
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastMonochrome = monochrome
        }

        if let target = currentMatchLineID, let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
        }

        if scrollTargetToken != context.coordinator.lastScrollToken,
           let target = scrollTargetLineID,
           let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
            context.coordinator.lastScrollToken = scrollTargetToken
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
        if monochrome {
            // Monochrome mode: use gray shades
            switch role {
            case .user:
                return (NSColor.labelColor, NSColor(white: 0.5, alpha: 0.18))
            case .assistant:
                return (NSColor.labelColor, NSColor(white: 0.4, alpha: 0.18))
            case .toolInput:
                return (NSColor.labelColor, NSColor(white: 0.6, alpha: 0.24))
            case .toolOutput:
                return (NSColor.labelColor, NSColor(white: 0.6, alpha: 0.16))
            case .error:
                return (NSColor.labelColor, NSColor(white: 0.3, alpha: 0.55))
            case .meta:
                return (NSColor.secondaryLabelColor, nil)
            }
        } else {
            // Color mode: original palette
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
