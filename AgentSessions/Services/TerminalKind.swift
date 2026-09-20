import Foundation

enum TerminalKind: String, CaseIterable, Sendable {
    case iterm2
    case warp
    case warpPreview
    case ghostty
    case kitty
    case wezTerm
    case terminalApp
    case unknown

    static var resumeChoices: [TerminalKind] {
        [.terminalApp] + allCases.filter { $0 != .terminalApp && $0 != .unknown }
    }

    /// Infer from process environment variables.
    /// `__CFBundleIdentifier` takes priority over `TERM_PROGRAM` to distinguish warp vs warpPreview.
    static func infer(termProgram: String?, cfBundleIdentifier: String?) -> TerminalKind {
        if let bundle = cfBundleIdentifier {
            switch bundle {
            case "dev.warp.Warp-Preview": return .warpPreview
            case "dev.warp.Warp-Stable":  return .warp
            case "dev.warp.Warp":         return .warp
            case "com.mitchellh.ghostty": return .ghostty
            case "net.kovidgoyal.kitty": return .kitty
            case "com.github.wez.wezterm": return .wezTerm
            default: break
            }
        }
        switch termProgram {
        case "iTerm.app":       return .iterm2
        case "Apple_Terminal":  return .terminalApp
        case "WarpTerminal":    return .warpPreview  // fallback if bundle ID missing
        case "ghostty":         return .ghostty
        case "kitty":           return .kitty
        case "WezTerm":         return .wezTerm
        default:                 return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .iterm2:      return "iTerm2"
        case .warp:        return "Warp"
        case .warpPreview: return "WarpPreview"
        case .ghostty:     return "Ghostty"
        case .kitty:       return "Kitty"
        case .wezTerm:     return "WezTerm"
        case .terminalApp: return "Terminal"
        case .unknown:     return "Unknown"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .iterm2:      return "com.googlecode.iterm2"
        case .warp:        return "dev.warp.Warp-Stable"
        case .warpPreview: return "dev.warp.Warp-Preview"
        case .ghostty:     return "com.mitchellh.ghostty"
        case .kitty:       return "net.kovidgoyal.kitty"
        case .wezTerm:     return "com.github.wez.wezterm"
        case .terminalApp: return "com.apple.Terminal"
        case .unknown:     return nil
        }
    }
}

func installedTerminalKinds(isInstalled: (String) -> Bool) -> [TerminalKind] {
    TerminalKind.resumeChoices.filter { kind in
        guard let bundleIdentifier = kind.bundleIdentifier else { return false }
        return isInstalled(bundleIdentifier)
    }
}
