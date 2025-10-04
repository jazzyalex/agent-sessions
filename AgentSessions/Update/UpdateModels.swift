import Foundation

// MARK: - GitHub API Response

struct GitHubRelease: Codable, Equatable {
    let tag_name: String
    let published_at: String
    let html_url: String
    let assets: [Asset]

    struct Asset: Codable, Equatable {
        let browser_download_url: String
    }
}

// MARK: - Update State

enum UpdateState: Equatable {
    case idle
    case checking
    case available(version: String, releaseURL: String, assetURL: String)
    case upToDate
    case error(String)
}
