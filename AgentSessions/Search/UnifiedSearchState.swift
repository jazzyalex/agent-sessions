import Foundation
import Combine

final class UnifiedSearchState: ObservableObject {
    @Published var query: String = ""
    @Published var autoJumpSessionID: String? = nil
    @Published var autoJumpToken: Int = 0

    func requestAutoJump(sessionID: String?) {
        autoJumpSessionID = sessionID
        autoJumpToken &+= 1
    }
}
