import Foundation

/// OpenCode 2.x owns execution in a shared service, independently of TUI/desktop
/// clients. Only the service's active IDs prove working sessions; persisted titles,
/// recent writes, and the server process itself do not prove a live conversation.
struct OpenCodeServicePresence {
    struct Registration: Decodable {
        let id: String
        let url: URL
        let pid: Int
        let password: String
    }

    private struct ActiveResponse: Decodable {
        struct State: Decodable { let type: String }
        let data: [String: State]
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func request(for registration: Registration) -> URLRequest? {
        let url = registration.url
        // Never forward a locally stored credential to a remote endpoint or a
        // redirect. The local service registration always names a loopback port.
        guard registration.pid > 1, registration.pid <= Int(Int32.max), !registration.id.isEmpty, !registration.password.isEmpty,
              url.scheme == "http", ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""),
              url.port != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        var request = URLRequest(url: url.appendingPathComponent("api/session/active"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        request.setValue("Basic " + Data("opencode:\(registration.password)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        return request
    }

    static func decode(_ data: Data, registration: Registration, now: Date) -> [CodexActivePresence]? {
        guard data.count <= 1024 * 1024,
              let response = try? JSONDecoder().decode(ActiveResponse.self, from: data) else { return nil }
        return response.data.sorted { $0.key < $1.key }.compactMap { id, state in
            guard id.hasPrefix("ses_"), id.count > 4, state.type == "running" else { return nil }
            var presence = CodexActivePresence()
            presence.schemaVersion = 1
            presence.source = .opencode
            presence.publisher = "agent-sessions-opencode-service"
            presence.kind = "service"
            presence.sessionId = id
            presence.pid = registration.pid
            presence.lastSeenAt = now
            presence.liveStateHint = .activeWorking
            return presence
        }
    }

    static func read(now: Date) async -> [CodexActivePresence] {
        let roots = await OpenCodePresenceIntegration.shared.stateRoots()
        let paths = roots.flatMap { root in
            (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        }
        let registrations = paths.filter {
            $0.lastPathComponent == "service.json" || ($0.lastPathComponent.hasPrefix("service-") && $0.pathExtension == "json")
        }.sorted { $0.path < $1.path }.prefix(16)
        return await withTaskGroup(of: [CodexActivePresence].self) { group in
            for path in registrations { group.addTask { await readRegistration(path, now: now) } }
            var result: [CodexActivePresence] = []
            for await presences in group { result.append(contentsOf: presences) }
            return result
        }
    }

    private static func readRegistration(_ path: URL, now: Date) async -> [CodexActivePresence] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024,
              let data = try? Data(contentsOf: path),
              let registration = try? JSONDecoder().decode(Registration.self, from: data),
              let request = request(for: registration),
              kill(Int32(registration.pid), 0) == 0 else { return [] }
        do {
            let (body, response) = try await session.data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return decode(body, registration: registration, now: now) ?? []
        } catch { return [] }
    }
}
