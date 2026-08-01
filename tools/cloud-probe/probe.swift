import Foundation

// Probe for the Claude cloud-session Runway rows feature.
//   spec: docs/superpowers/specs/2026-07-31-claude-cloud-session-source-design.md §3
//   verdict 2026-07-31: GO — 177 sessions enumerate with full liveness fields.
//
// Lists cloud sessions and tallies the status vocabulary. Structure only:
// exactly one title is echoed (the one being searched for); all others stay redacted.
//
// Run:
//   CLAUDE_SESSION_KEY="$(security find-generic-password \
//     -s 'com.triada.AgentSessions.claude-web' -w)" swift tools/cloud-probe/probe.swift
//
// Two gotchas this file exists to preserve:
//
//   1. Use URLSession, NOT curl. curl gets 403 + a Cloudflare HTML interstitial on every
//      claude.ai path even with a valid sessionKey — TLS fingerprinting, not auth. A
//      curl-based probe of this API reports false negatives.
//   2. /v1/code/sessions is a DIFFERENT API base from /api/organizations/... . The latter
//      is the chat surface and contains no code sessions; probing it produced a false NO-GO.
//
// Read-only: GET only.

let key = ProcessInfo.processInfo.environment["CLAUDE_SESSION_KEY"] ?? ""
let org = "89ec7e97-8330-4091-8fc7-c3dc60caace4"
let config = URLSessionConfiguration.ephemeral
config.timeoutIntervalForRequest = 20
let session = URLSession(configuration: config)

func fetch(_ url: String) async -> [String: Any]? {
    var req = URLRequest(url: URL(string: url)!)
    req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
    req.setValue("ccr", forHTTPHeaderField: "anthropic-client-feature")
    req.setValue(org, forHTTPHeaderField: "x-organization-uuid")
    req.setValue("Mozilla/5.0 AgentSessions", forHTTPHeaderField: "User-Agent")
    guard let (d, _) = try? await session.data(for: req) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

var all: [[String: Any]] = []
var cursor: String? = nil
for _ in 0..<6 {
    var u = "https://claude.ai/v1/code/sessions?limit=100"
    if let c = cursor { u += "&cursor=\(c)" }
    guard let obj = await fetch(u), let rows = obj["data"] as? [[String: Any]], !rows.isEmpty else { break }
    all += rows
    cursor = obj["next_cursor"] as? String
    if cursor == nil { break }
}
print("total cloud sessions listed: \(all.count)")

func tally(_ k: String) {
    var c: [String: Int] = [:]
    for r in all { c[String(describing: r[k] ?? "nil"), default: 0] += 1 }
    let t = c.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    print("  \(k): \(t)")
}
tally("status")
tally("status_bucket")
tally("worker_status")
tally("connection_status")
tally("environment_kind")

let hit = all.first { (($0["title"] as? String) ?? "").lowercased().contains("pingcraft") }
print("")
if let h = hit {
    print("PingCraft FOUND in list ✓")
    print("  title            : \(h["title"] as? String ?? "")")
    print("  id               : \(String((h["id"] as? String ?? "").prefix(12)))…")
    print("  status           : \(h["status"] ?? "nil")")
    print("  status_bucket    : \(h["status_bucket"] ?? "nil")")
    print("  worker_status    : \(h["worker_status"] ?? "nil")")
    print("  connection_status: \(h["connection_status"] ?? "nil")")
    print("  last_event_at    : \(h["last_event_at"] ?? "nil")")
    print("  unread           : \(h["unread"] ?? "nil")")
    print("  user_msg_count   : \(h["user_message_count"] ?? "nil")")
    print("  environment_kind : \(h["environment_kind"] ?? "nil")")
    if let rel = h["relations"] { print("  relations        : \(String(String(describing: rel).prefix(160)))") }
} else {
    print("PingCraft NOT in list ✗")
}
