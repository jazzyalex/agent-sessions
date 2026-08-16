import Foundation
import Combine

// MARK: - Publishers.combineLatestArray (SPEC §3.4)
//
// Combine ships `CombineLatest2…4` and nothing else, so every N-source pipeline in this
// app was written as a hand-nested tuple pyramid — `CombineLatest3(CombineLatest4, …)`
// plus a tail of `.combineLatest(…)` calls, each one destructured by position downstream.
// That shape is why adding a source is a 12-site edit and why a forgotten arm silently
// drops a provider out of a pipeline (SPEC §1, bugs 1–2).
//
// This fold is the replacement primitive: it takes a registry-ordered array and emits a
// registry-ordered array, so consumers zip the output against `SessionSourceRegistry.ordered`
// instead of unpacking `((((a, b), c), d), e)`.
//
// Semantics are exactly `CombineLatestN`'s, which is what makes it a drop-in for the
// pyramids (and why `MergeMany` is NOT the right primitive — it interleaves single values
// instead of holding the latest of each):
//   * no output until EVERY upstream has produced its first value;
//   * thereafter one output per upstream emission, carrying the latest of all of them;
//   * the empty array is the identity — it emits `[]` once, immediately, rather than
//     never completing, so a caller that folds over an empty source list still gets its
//     initial callback.
extension Publishers {
    static func combineLatestArray<Output>(
        _ publishers: [AnyPublisher<Output, Never>]
    ) -> AnyPublisher<[Output], Never> {
        guard let first = publishers.first else {
            return Just([]).eraseToAnyPublisher()
        }
        let seed = first.map { [$0] }.eraseToAnyPublisher()
        return publishers.dropFirst().reduce(seed) { accumulated, next in
            accumulated
                .combineLatest(next) { $0 + [$1] }
                .eraseToAnyPublisher()
        }
    }
}
