import Foundation

// MARK: - Protocol

protocol GitHubAPIClient {
    func fetchLatestRelease(etag: String?) async -> Result<(GitHubRelease, etag: String?), Error>
}

// MARK: - HTTP Implementation

final class GitHubHTTPClient: GitHubAPIClient {
    private let session: URLSession
    private let repoOwner: String
    private let repoName: String

    init(session: URLSession = .shared, repoOwner: String = "jazzyalex", repoName: String = "agent-sessions") {
        self.session = session
        self.repoOwner = repoOwner
        self.repoName = repoName
    }

    func fetchLatestRelease(etag: String?) async -> Result<(GitHubRelease, etag: String?), Error> {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            return .failure(GitHubClientError.invalidURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(GitHubClientError.invalidResponse)
            }

            // Handle 304 Not Modified
            if httpResponse.statusCode == 304 {
                return .failure(GitHubClientError.notModified)
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                return .failure(GitHubClientError.httpError(httpResponse.statusCode))
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let newETag = httpResponse.value(forHTTPHeaderField: "ETag")
            return .success((release, newETag))

        } catch let error as DecodingError {
            return .failure(GitHubClientError.decodingError(error.localizedDescription))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Errors

enum GitHubClientError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case notModified
    case decodingError(String)

    static func == (lhs: GitHubClientError, rhs: GitHubClientError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse),
             (.notModified, .notModified):
            return true
        case (.httpError(let a), .httpError(let b)):
            return a == b
        case (.decodingError(let a), .decodingError(let b)):
            return a == b
        default:
            return false
        }
    }
}

extension GitHubClientError {
    init(decodingError: DecodingError) {
        self = .decodingError(decodingError.localizedDescription)
    }
}
