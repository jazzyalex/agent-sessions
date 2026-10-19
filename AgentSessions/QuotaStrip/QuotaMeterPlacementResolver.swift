import Foundation
import CoreGraphics

/// Pure placement logic for the Quota Meter (floating window vs menu bar strip).
/// Compiled into the app and the hostless logic-test target.
enum PlacementChoice: String {
    case floating, menuBar, automatic
}

struct PlacementScreen: Equatable {
    let id: UInt32
    let frame: CGRect
    let isBuiltin: Bool
}

enum PlacementDecision: Equatable {
    case floating
    case strip(screenID: UInt32)
}

enum QuotaMeterPlacementResolver {
    /// `menuBar`: strip on the target screen. `automatic`: strip only when the target screen is
    /// the built-in display. `floating`, or no screens: floating window.
    /// `preferBuiltin`: the strip left the built-in display only because that display went
    /// away (lid closed); while it is back, `automatic` returns to it whatever screen the
    /// auto-opened floating window was moved to.
    static func resolve(_ choice: PlacementChoice, screens: [PlacementScreen],
                        floatingFrame: CGRect?, preferBuiltin: Bool = false) -> PlacementDecision {
        if preferBuiltin, choice == .automatic, let builtin = screens.first(where: \.isBuiltin) {
            return .strip(screenID: builtin.id)
        }
        guard choice != .floating, let target = targetScreen(screens: screens, floatingFrame: floatingFrame) else {
            return .floating
        }
        switch choice {
        case .menuBar: return .strip(screenID: target.id)
        case .automatic: return target.isBuiltin ? .strip(screenID: target.id) : .floating
        case .floating: return .floating
        }
    }

    /// The screen with the largest intersection with the floating window's frame;
    /// the first screen when the frame is absent or on no connected screen.
    static func targetScreen(screens: [PlacementScreen], floatingFrame: CGRect?) -> PlacementScreen? {
        guard let floatingFrame else { return screens.first }
        let best = screens
            .map { ($0, area($0.frame.intersection(floatingFrame))) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        return best?.0 ?? screens.first
    }

    private static func area(_ r: CGRect) -> CGFloat {
        r.isNull ? 0 : r.width * r.height
    }
}

enum QuotaMeterPlacementDefaults {
    /// The value to write at launch, or nil when one is already stored. Fresh installs get
    /// `automatic`; old menu bar item users get `menuBar`; other existing installs `floating`.
    static func valueToWrite(storedRaw: String?, menuBarEnabled: Bool, isFreshInstall: Bool) -> PlacementChoice? {
        guard storedRaw == nil else { return nil }
        if menuBarEnabled { return .menuBar }
        return isFreshInstall ? .automatic : .floating
    }
}

/// The usage models' cockpit signal, combined over every Quota Meter surface on screen.
/// The strip stays on screen like a pinned window, so it always counts as pinned.
struct QuotaMeterPollingSignal: Equatable {
    enum Surface: Equatable {
        case window(pinned: Bool)
        case strip
    }

    let visible: Bool
    let pinned: Bool

    static func combine(_ surfaces: [Surface]) -> QuotaMeterPollingSignal {
        let pinned = surfaces.contains { surface in
            switch surface {
            case .window(let pinned): return pinned
            case .strip: return true
            }
        }
        return QuotaMeterPollingSignal(visible: !surfaces.isEmpty, pinned: pinned)
    }
}
