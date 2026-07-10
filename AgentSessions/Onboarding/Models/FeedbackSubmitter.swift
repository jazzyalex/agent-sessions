import Foundation

/// The user input plus the small context tag we attach. Everything here is folded
/// into a single Google Form paragraph field — nothing is transmitted that isn't
/// represented in this struct.
struct FeedbackPayload: Equatable {
    let feedback: String
    let email: String?
    let appVersion: String
    let macOSMajorVersion: Int
}

enum FeedbackSubmitError: Error, Equatable {
    /// Non-2xx HTTP response.
    case badStatus(Int)
    /// Transport/URL error.
    case transport(String)
    /// Response was not an HTTP response.
    case notHTTP
}

/// Fires a single POST to a Google Form's `formResponse` endpoint when the user
/// presses Send. No retry queue, no background scheduling — the network call
/// happens only on an explicit Send. Google Forms is the backend so there is no
/// server to run or maintain; responses land in the form's linked sheet.
struct FeedbackSubmitter {
    // ============================================================================
    // MARK: Google Form backend
    //
    // These point at the existing "Agent Sessions User Survey" form. To send to a
    // different form instead:
    //   1. Open the *live* (published) form in a browser.
    //   2. View source and find `.../forms/d/e/<ID>/formResponse` → that's the URL.
    //   3. Find the free-text question's field name (`entry.<digits>`) in the same
    //      source → that's `feedbackEntryField`.
    // The paragraph field is optional on the form, so a partial submission (only
    // this field) is accepted.
    // ============================================================================
    static let formResponseURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScfkvsHvLs2LgikKDTK1Pl-PE_VPFR1Qs5Axlz1RRhevP6T2g/formResponse")!
    /// The form's "Feature Request/Comment" paragraph question.
    static let feedbackEntryField = "entry.1909608576"

    /// GitHub fallbacks surfaced under the field when a send fails.
    static let githubIssuesURL = URL(string: "https://github.com/jazzyalex/agent-sessions/issues/new")!
    static let githubDiscussionsURL = URL(string: "https://github.com/jazzyalex/agent-sessions/discussions")!

    let endpoint: URL
    let entryField: String
    let session: URLSession

    init(
        endpoint: URL = FeedbackSubmitter.formResponseURL,
        entryField: String = FeedbackSubmitter.feedbackEntryField,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.entryField = entryField
        self.session = session
    }

    func submit(_ payload: FeedbackPayload) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(for: payload, entryField: entryField)

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw FeedbackSubmitError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackSubmitError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedbackSubmitError.badStatus(http.statusCode)
        }
    }

    /// The exact `application/x-www-form-urlencoded` body sent to Google Forms.
    static func formBody(for payload: FeedbackPayload, entryField: String) -> Data {
        let pairs = [
            (entryField, composedMessage(for: payload)),
            ("fvv", "1"),
            ("pageHistory", "0"),
            ("submit", "Submit")
        ]
        let body = pairs
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    /// The single paragraph value: the user's note, then a one-line context tag.
    static func composedMessage(for payload: FeedbackPayload) -> String {
        var tag = "— Agent Sessions \(payload.appVersion), macOS \(payload.macOSMajorVersion)"
        if let email = payload.email, !email.isEmpty {
            tag += " · reply: \(email)"
        }
        return "\(payload.feedback)\n\n\(tag)"
    }

    /// Percent-encodes for a form body using only unreserved characters, so spaces
    /// become %20 and a literal "+" becomes %2B (never a decode-ambiguous "+").
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Builds a payload from the current app + OS environment plus user input.
    static func makePayload(feedback: String, email: String?) -> FeedbackPayload {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let macMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedbackPayload(
            feedback: feedback,
            email: (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil,
            appVersion: appVersion,
            macOSMajorVersion: macMajor
        )
    }
}
