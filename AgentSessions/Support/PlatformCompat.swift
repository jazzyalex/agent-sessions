import Foundation

// Stand-ins for Darwin-only Foundation APIs that the shared session core touches, so the
// same sources build on Linux for the `as-core` CLI. Nothing here compiles on macOS.

#if !canImport(ObjectiveC)
/// No autorelease pools without the Objective-C runtime; run the body directly.
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

#if !canImport(Darwin)
/// Plain `String` stands in for localized resources; Linux output is not localized.
public typealias LocalizedStringResource = String

/// Minimal English-only replacement for Foundation's `RelativeDateTimeFormatter`
/// (absent from swift-corelibs-foundation), covering the `.short` style the core uses.
final class RelativeDateTimeFormatter {
    enum UnitsStyle { case full, spellOut, short, abbreviated }
    var unitsStyle: UnitsStyle = .full

    func localizedString(for date: Date, relativeTo referenceDate: Date) -> String {
        let delta = referenceDate.timeIntervalSince(date)
        let magnitude = abs(delta)
        let units: [(Double, String)] = [(31_536_000, "yr."), (2_592_000, "mo."), (604_800, "wk."),
                                         (86_400, "day"), (3_600, "hr."), (60, "min."), (1, "sec.")]
        guard let (size, label) = units.first(where: { magnitude >= $0.0 }) else { return "now" }
        let count = Int(magnitude / size)
        return delta >= 0 ? "\(count) \(label) ago" : "in \(count) \(label)"
    }
}
#endif
