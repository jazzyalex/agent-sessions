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

    /// Encode the id for line `lineOrdinal` (0-based, reset per block) of block
    /// `globalBlockIndex` (0-based over the full coalesced-block stream).
    ///
    /// Invariants (fail loud in DEBUG rather than silently corrupt an id):
    /// - `globalBlockIndex >= 0` — real blocks only; synthetic/meta lines with no
    ///   real block must use `makeSyntheticID` (a negative index here would produce
    ///   a negative id that `globalBlockIndex(from:)` misreads as synthetic).
    /// - `0 <= lineOrdinal < stride` — a block contributing `>= stride` lines would
    ///   alias into the next block's id space. Real blocks are at most a few thousand
    ///   lines; the assert catches any pathological session in testing.
    static func makeID(globalBlockIndex: Int, lineOrdinal: Int) -> Int {
        assert(globalBlockIndex >= 0,
               "TerminalLineID.makeID: globalBlockIndex must be >= 0 (got \(globalBlockIndex)); use makeSyntheticID for meta lines")
        assert(lineOrdinal >= 0 && lineOrdinal < stride,
               "TerminalLineID.makeID: lineOrdinal \(lineOrdinal) out of 0..<\(stride); block would alias into the next block's id space")
        return globalBlockIndex * stride + lineOrdinal
    }

    /// Encode a globally-stable synthetic (negative) id for a meta line that has no
    /// real block (system-reminder / interrupt / local-command wrapper). Derived
    /// from the OWNING block's global index plus a per-block synthetic ordinal, so
    /// the id is stable across windowed slices (a prepended older window and the
    /// current window never collide on `-1`) and never aliases a real (`>= 0`) id
    /// or a synthetic id from another block.
    ///
    /// Encoding: `-(globalBlockIndex * stride + syntheticOrdinal) - 1` — always
    /// `<= -1` (so `globalBlockIndex(from:)` still classifies it synthetic), and
    /// bijective in `(globalBlockIndex, syntheticOrdinal)` for ordinals `< stride`.
    static func makeSyntheticID(globalBlockIndex: Int, syntheticOrdinal: Int) -> Int {
        assert(globalBlockIndex >= 0,
               "TerminalLineID.makeSyntheticID: globalBlockIndex must be >= 0 (got \(globalBlockIndex))")
        assert(syntheticOrdinal >= 0 && syntheticOrdinal < stride,
               "TerminalLineID.makeSyntheticID: syntheticOrdinal \(syntheticOrdinal) out of 0..<\(stride)")
        return -(globalBlockIndex * stride + syntheticOrdinal) - 1
    }

    /// Decode the global block index from an id, or nil if the id is synthetic
    /// (negative) and therefore not tied to a real block.
    static func globalBlockIndex(from id: Int) -> Int? {
        guard id >= 0 else { return nil }
        return id / stride
    }
}
