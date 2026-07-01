import Foundation

/// Encoding scheme for stable, GLOBAL `TerminalLine` identities.
///
/// A line id is `globalBlockIndex * stride + lineOrdinalWithinBlock`. Because the
/// global block index is stable across any slice of the coalesced-block stream,
/// the id of a given block's given line does not depend on how many blocks/lines
/// preceded it in the built slice — so a later prepended window never renumbers
/// existing lines.
///
/// Ids are required to be **unique** and **monotonic in render order**; they are
/// intentionally NOT contiguous-from-zero. The view uses `line.id` only as a
/// dictionary key and for `sorted()` / `firstIndex(of:)` / `first(where:)`
/// lookups, never as a raw array subscript.
enum TerminalLineID {
    /// Maximum lines a single coalesced block can contribute before ids would
    /// collide with the next block. Real blocks are at most a few thousand lines.
    static let stride = 1_000_000

    /// Synthetic (meta) lines that have no real block index get negative ids in a
    /// separate space so they never collide with real (`>= 0`) block ids.
    static let syntheticIDBase = -1

    /// Encode the id for line `lineOrdinal` (0-based, reset per block) of block
    /// `globalBlockIndex` (0-based over the full coalesced-block stream).
    static func makeID(globalBlockIndex: Int, lineOrdinal: Int) -> Int {
        globalBlockIndex * stride + lineOrdinal
    }

    /// Encode a synthetic (negative) id for a meta line with no real block index.
    /// `syntheticCounter` increments per synthetic line within a single build.
    static func makeSyntheticID(syntheticCounter: Int) -> Int {
        syntheticIDBase - syntheticCounter
    }

    /// Decode the global block index from an id, or nil if the id is synthetic
    /// (negative) and therefore not tied to a real block.
    static func globalBlockIndex(from id: Int) -> Int? {
        guard id >= 0 else { return nil }
        return id / stride
    }
}
