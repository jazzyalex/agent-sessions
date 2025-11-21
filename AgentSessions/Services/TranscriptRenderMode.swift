import Foundation

public enum TranscriptRenderMode: String, CaseIterable, Identifiable, Codable {
    case normal
    case terminal
    case json
    public var id: String { rawValue }
}
