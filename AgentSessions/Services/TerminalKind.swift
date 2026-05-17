import Foundation

enum TerminalKind: String, CaseIterable, Sendable {
    case iterm2
    case warp
    case warpPreview
    case terminalApp
    case ghostty
    case unknown

    /// Infer from process environment variables.
    /// `__CFBundleIdentifier` takes priority over `TERM_PROGRAM` to distinguish warp vs warpPreview.
    static func infer(termProgram: String?, cfBundleIdentifier: String?) -> TerminalKind {
        if let bundle = cfBundleIdentifier {
            switch bundle {
            case "dev.warp.Warp-Preview": return .warpPreview
            case "dev.warp.Warp":         return .warp
            default: break
            }
        }
        switch termProgram {
        case "iTerm.app":       return .iterm2
        case "Apple_Terminal":  return .terminalApp
        case "WarpTerminal":    return .warpPreview  // fallback if bundle ID missing
        case "ghostty":         return .ghostty
        default:                return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .iterm2:      return "iTerm2"
        case .warp:        return "Warp"
        case .warpPreview: return "WarpPreview"
        case .terminalApp: return "Terminal"
        case .ghostty:     return "Ghostty"
        case .unknown:     return "Unknown"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .iterm2:      return "com.googlecode.iterm2"
        case .warp:        return "dev.warp.Warp"
        case .warpPreview: return "dev.warp.Warp-Preview"
        case .terminalApp: return "com.apple.Terminal"
        case .ghostty:     return "com.mitchellh.ghostty"
        case .unknown:     return nil
        }
    }

    /// URL scheme for opening a new tab at a given path.
    func newTabURL(cwd: String?) -> URL? {
        let scheme: String
        switch self {
        case .warp:        scheme = "warp"
        case .warpPreview: scheme = "warppreview"
        default:           return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "action"
        components.path = "/new_tab"
        if let cwd, !cwd.isEmpty {
            components.queryItems = [URLQueryItem(name: "path", value: cwd)]
        }
        return components.url
    }

    var focusButtonLabel: String {
        switch self {
        case .iterm2:      return "Focus in iTerm2"
        case .warp:        return "Focus in Warp"
        case .warpPreview: return "Focus in Warp"
        case .terminalApp: return "Focus in Terminal"
        case .ghostty:     return "Focus"
        case .unknown:     return "Focus"
        }
    }

    var processName: String? {
        switch self {
        case .warp, .warpPreview: return "preview"
        case .iterm2:             return "iTerm2"
        case .terminalApp:        return "Terminal"
        default:                  return nil
        }
    }
}

enum TerminalFocusResult {
    case exact
    case appOnly
    case unavailable
}
