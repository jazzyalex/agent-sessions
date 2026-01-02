import SwiftUI
#if os(macOS)
import AppKit
#endif

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light Mode"
        case .dark: return "Dark Mode"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func effectiveColorScheme(systemScheme: ColorScheme) -> ColorScheme {
        switch self {
        case .system: return systemScheme
        case .light: return .light
        case .dark: return .dark
        }
    }

    func toggledDarkLight(systemScheme: ColorScheme) -> AppAppearance {
        let effective = effectiveColorScheme(systemScheme: systemScheme)
        return effective == .dark ? .light : .dark
    }

    #if os(macOS)
    static func systemColorSchemeFallback() -> ColorScheme {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return (match == .darkAqua) ? .dark : .light
    }
    #endif
}
