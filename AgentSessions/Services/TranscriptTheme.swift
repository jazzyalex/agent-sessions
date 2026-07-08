import SwiftUI

enum TranscriptTheme: String, CaseIterable, Identifiable {
    case codexDark
    case monochrome
    case ansiExport
    var id: String { rawValue }
}

struct TranscriptColors {
    let user: Color
    let assistant: Color
    let tool: Color
    let output: Color
    let error: Color
    let dim: Color
}

extension TranscriptTheme {
    var colors: TranscriptColors {
        switch self {
        case .codexDark, .ansiExport:
            // Delegate to the single semantic palette so this path can't drift
            // from the live block/terminal renderers. (Currently unused for UI —
            // ANSI export uses escape codes in SessionTranscriptBuilder; kept
            // consistent so a future revival stays on one source of truth.)
            return TranscriptColors(
                user: TranscriptColorSystem.semanticAccent(.user),
                assistant: TranscriptColorSystem.semanticAccent(.assistant),
                tool: TranscriptColorSystem.semanticAccent(.toolCall),
                output: .primary,
                error: TranscriptColorSystem.semanticAccent(.error),
                dim: .secondary
            )
        case .monochrome:
            return TranscriptColors(user: .primary, assistant: .primary, tool: .primary, output: .primary, error: .primary, dim: .secondary)
        }
    }
}

enum TranscriptFilters: Equatable {
    case current(showTimestamps: Bool, showMeta: Bool)
}
