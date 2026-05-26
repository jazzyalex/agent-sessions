import Foundation

enum TerminalKind: String, CaseIterable, Sendable {
    case iterm2
    case warp
    case warpPreview
    case terminalApp
    case unknown

    /// Infer from process environment variables.
    /// `__CFBundleIdentifier` takes priority over `TERM_PROGRAM` to distinguish warp vs warpPreview.
    static func infer(termProgram: String?, cfBundleIdentifier: String?) -> TerminalKind {
        if let bundle = cfBundleIdentifier {
            switch bundle {
            case "dev.warp.Warp-Preview": return .warpPreview
            case "dev.warp.Warp-Stable":  return .warp
            case "dev.warp.Warp":         return .warp
            default: break
            }
        }
        switch termProgram {
        case "iTerm.app":       return .iterm2
        case "Apple_Terminal":  return .terminalApp
        case "WarpTerminal":    return .warpPreview  // fallback if bundle ID missing
        default:                return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .iterm2:      return "iTerm2"
        case .warp:        return "Warp"
        case .warpPreview: return "WarpPreview"
        case .terminalApp: return "Terminal"
        case .unknown:     return "Unknown"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .iterm2:      return "com.googlecode.iterm2"
        case .warp:        return "dev.warp.Warp-Stable"
        case .warpPreview: return "dev.warp.Warp-Preview"
        case .terminalApp: return "com.apple.Terminal"
        case .unknown:     return nil
        }
    }

}
