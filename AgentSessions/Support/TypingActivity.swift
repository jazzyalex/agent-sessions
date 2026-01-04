import Foundation

final class TypingActivity: @unchecked Sendable {
    static let shared = TypingActivity()
    private var lastType = Date.distantPast
    private let lock = NSLock()

    func bump() {
        lock.lock(); lastType = Date(); lock.unlock()
    }

    var isUserLikelyTyping: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastType) < 0.8 // 800ms quiet window
    }
}
