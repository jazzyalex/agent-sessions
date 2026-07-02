import Foundation

/// Linear-time replacement for the per-block "nearest user block" scan used by
/// the transcript rebuild index maps. Semantics are pinned to the legacy
/// implementation: prefer the last non-preamble user block at/before the index,
/// then the last user block at/before it, then the first non-preamble user
/// block after it, then the first user block after it.
enum TranscriptUserAnchors {
    static func anchors(userBlockIndices: [Int],
                        preambleUserBlockIndexes: Set<Int>,
                        blockCount: Int) -> [Int?] {
        guard blockCount > 0 else { return [] }
        var result = [Int?](repeating: nil, count: blockCount)

        // Forward: last user at/before idx, preferring non-preamble.
        var u = 0
        var lastUser: Int? = nil
        var lastNonPreamble: Int? = nil
        for idx in 0..<blockCount {
            while u < userBlockIndices.count, userBlockIndices[u] <= idx {
                lastUser = userBlockIndices[u]
                if !preambleUserBlockIndexes.contains(userBlockIndices[u]) {
                    lastNonPreamble = userBlockIndices[u]
                }
                u += 1
            }
            result[idx] = lastNonPreamble ?? lastUser
        }

        // Backward fill for blocks with no user block at/before them: first user
        // after idx, preferring non-preamble.
        var v = userBlockIndices.count - 1
        var firstAfter: Int? = nil
        var firstNonPreambleAfter: Int? = nil
        for idx in stride(from: blockCount - 1, through: 0, by: -1) {
            while v >= 0, userBlockIndices[v] > idx {
                firstAfter = userBlockIndices[v]
                if !preambleUserBlockIndexes.contains(userBlockIndices[v]) {
                    firstNonPreambleAfter = userBlockIndices[v]
                }
                v -= 1
            }
            if result[idx] == nil {
                result[idx] = firstNonPreambleAfter ?? firstAfter
            }
        }
        return result
    }
}
