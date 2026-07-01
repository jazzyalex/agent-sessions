import Foundation

/// A contiguous, inclusive range of **global** coalesced-block indices currently
/// loaded into the terminal transcript.
///
/// The block array fed to the window is already coalesced — every `canMerge`
/// chain (same `messageID` / delta run / tool stream) is a single `LogicalBlock`.
/// Therefore *any* block-index range is boundary-safe: a window can never cut
/// inside a merge chain. This type only decides which range to load and owns the
/// window-size policy; it never slices raw events.
struct TranscriptWindow: Equatable, Sendable {
    /// Lowest global block index in the window (inclusive).
    let lowerBlock: Int
    /// Highest global block index in the window (inclusive).
    let upperBlock: Int

    var isEmpty: Bool { lowerBlock > upperBlock }

    var blockCount: Int { isEmpty ? 0 : upperBlock - lowerBlock + 1 }

    /// True when there is nothing older to load (the window reaches block 0).
    var coversTop: Bool { lowerBlock <= 0 }

    /// True when there is nothing newer to load (the window reaches the last block).
    func coversBottom(totalBlocks: Int) -> Bool { upperBlock >= totalBlocks - 1 }

    /// The last `blockTarget` whole blocks (or all blocks if fewer).
    static func lastWindow(totalBlocks: Int, blockTarget: Int) -> TranscriptWindow {
        guard totalBlocks > 0 else {
            return TranscriptWindow(lowerBlock: 0, upperBlock: -1)
        }
        let target = max(1, blockTarget)
        let lower = max(0, totalBlocks - target)
        return TranscriptWindow(lowerBlock: lower, upperBlock: totalBlocks - 1)
    }

    /// Extend the window downward (older) by `blockTarget` whole blocks, clamped at 0.
    func expandedOlder(blockTarget: Int) -> TranscriptWindow {
        guard !isEmpty else { return self }
        let target = max(1, blockTarget)
        return TranscriptWindow(lowerBlock: max(0, lowerBlock - target), upperBlock: upperBlock)
    }

    /// Extend the window upward (newer) by `blockTarget` whole blocks, clamped at
    /// `totalBlocks - 1`.
    func expandedNewer(totalBlocks: Int, blockTarget: Int) -> TranscriptWindow {
        guard !isEmpty, totalBlocks > 0 else { return self }
        let target = max(1, blockTarget)
        return TranscriptWindow(lowerBlock: lowerBlock,
                                upperBlock: min(totalBlocks - 1, upperBlock + target))
    }
}
