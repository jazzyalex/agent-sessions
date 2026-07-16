# Claude Web-Usage Path: Embedded Login (Bug 2) — Design Spec

> Status: SUPERSEDED (2026-07-16). The honesty fix shipped as designed. For the
> durable web source the owner chose the **safe manual cookie paste** over the
> embedded WKWebView login below: on-machine verification confirmed the claude.ai
> `sessionKey` is not in any readable binarycookies file (nor in the WebsiteDataStore
> tree, which is absent) on modern Safari, so scraping can't be rescued — and the
> paste path (CodexBar's actual Claude approach) is FDA-free, WebView-free, and
> CAPTCHA-free. Shipped: `ClaudeManualWebCookie.swift` (extractor + Keychain store),
> wired as the PRIMARY web source in `ClaudeUsageSourceManager.performWebFetch`;
> `ClaudeWebCookieResolver` widened to typed outcomes + value-free diagnostics and
> demoted to a legacy fallback; paste UI in `PreferencesView+Usage.swift`. The
> embedded-login design below is retained for reference only.
> Companion bug: Bug 1 (wedged OAuth/delegated-refresh latch) is being fixed
> separately; see `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift`.

## Problem

For users **without** the Claude CLI, the Web API path is the ONLY way Agent
Sessions can read Claude subscription usage. It is currently broken on modern
macOS, and it lies about why.

### Confirmed root cause (evidence-backed, 2026-07-16)

The app reads the **wrong cookie store**. `ClaudeWebCookieResolver` parses only:

- `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`
- legacy `~/Library/Cookies/Cookies.binarycookies`

Both are the old NSHTTPCookieStorage-era binarycookies files. On macOS 14/15,
Safari keeps its **browsing** session cookies in the WebKit network data store,
not these legacy files — so claude.ai's `sessionKey` is not there.

Proven on macOS 15.7.7, official app, user signed into claude.ai (default
profile, no Safari profiles):

1. Full Disk Access granted → resolver returns `.noSession`, NOT
   `.permissionDenied`, so the read itself succeeds. (`ClaudeWebCookieResolver.swift`
   `parseSafariCookiesDetailed`.)
2. Fully quitting Safari flushed the legacy file (mtime advanced 11:27:53 →
   11:39:52), yet the app still found no live `sessionKey`.
3. Nothing about the setup is unusual → this is almost certainly broken for
   **every** Safari user on macOS 14/15, not one machine.

The parser format itself is NOT the bug: Codex verified the binarycookies
offsets match the documented layout (page sizes BE; record offsets LE; url/name/
value at 16/20/28; expiry float64 LE at 40, Apple-2001 epoch). The cookie is
simply not in the file being read.

### Secondary defect: `.noSession` collapses six failure worlds

`ClaudeWebCookieResolver.ReadOutcome` has only `.found` / `.permissionDenied` /
`.noSession`. Every structural parser miss returns nil → `.noSession`, which the
UI renders as "No claude.ai session in Safari — sign in at claude.ai (default
profile), then retest." (`PreferencesView+Usage.swift:601`.) That message is a
lie when the user IS signed in — the app cannot distinguish "signed out" from "I
read the wrong/empty file". This is why the user re-signed-in repeatedly to no
effect.

## Goals

1. CLI-less users can read Claude subscription usage on current macOS, durably.
2. Stop depending on scraping Safari's private cookie store (undocumented; it has
   already moved once and will move again).
3. Never tell a signed-in user to "sign in".

## Non-goals

- Do not touch the OAuth/CLI path (that is Bug 1's territory and is the primary,
  more-robust source for CLI users).
- Do not claim `/api/oauth/usage` or claude.ai org-usage routes are stable
  official APIs — they are undocumented; the whole web path is a compatibility
  adapter and must be labeled as such internally.

## Approach — recommended: app-owned embedded login (WKWebView + WKWebsiteDataStore)

The user signs into claude.ai **inside** Agent Sessions once, in a `WKWebView`
backed by a persistent app-owned `WKWebsiteDataStore`. The app then owns the
session cookie directly via
`dataStore.httpCookieStore.getAllCookies { ... }` and reads the `sessionKey`
from there.

This removes, in one move:
- Full Disk Access requirement (no foreign container reads).
- Safari-profile dependency.
- Cookie flush-timing dependency.
- Cookie-store-location dependency (the thing that broke it).

### Components

- `ClaudeWebLoginView` (SwiftUI wrapper over `WKWebView`) — presents
  `https://claude.ai/login`, detects successful auth (URL/cookie transition),
  dismisses. Sign-in is user-driven inside the sheet; the app never handles
  credentials directly (no autofill, no password entry on the user's behalf).
- `ClaudeWebSessionStore` — owns the persistent `WKWebsiteDataStore` (a stable
  identifier so the session survives relaunch), exposes
  `func currentSessionKey() async -> String?` reading `httpCookieStore`.
- Replace `ClaudeWebCookieResolver`'s Safari-file scraping as the PRIMARY source
  with `ClaudeWebSessionStore`. Keep the Safari-file reader ONLY as an optional
  legacy import ("import an existing Safari session") if it still works for
  anyone — but it must no longer be the path a normal user is told to use.
- Wire into `ClaudeUsageSourceManager`'s web-fallback branch: where it currently
  calls the cookie resolver, call the app-owned session first.

### Interface sketch

```swift
protocol ClaudeWebSession {
    /// Live sessionKey from the app-owned data store, or nil if not signed in.
    func currentSessionKey() async -> String?
    /// True once a claude.ai session cookie exists in the app store.
    func hasSession() async -> Bool
}
```

The usage client (`ClaudeWebUsageClient`) already takes a token/cookie; feed it
the app-owned `sessionKey`.

## Smaller, ship-first honesty fix (do this regardless, even before the rewrite)

Independent of the embedded login, fix the lie now:

1. Widen `ClaudeWebCookieResolver.ReadOutcome` to typed cases:
   `found` / `permissionDenied` / `storeMissing` / `validStoreNoCookie` /
   `unsupportedFormat` / `malformedRecord` / `cookieExpired`. Return the specific
   one instead of collapsing to `.noSession`.
2. Add value-free diagnostic logging at parse time: magic OK?, page count,
   record count, total cookies seen, count matching `.claude.ai`, count named
   `sessionKey`, and expiry status of any match. NEVER log cookie values.
3. Change the Preferences → Usage caption: when FDA is granted but no cookie is
   found, say "Couldn't find a Safari claude.ai session — Safari changed where it
   stores cookies on macOS 14+. Use the CLI, or sign in inside Agent Sessions
   (embedded login)." Not "sign in at claude.ai (default profile)".

## Testing

- Fixture test for the binarycookies parser using a REAL sanitized macOS 15.7
  cookie page (values redacted), covering: valid store with cookie, valid store
  without the cookie, malformed record, expired cookie. Locks the typed outcomes.
- `ClaudeWebSessionStore`: integration test that a cookie written to the
  app-owned `WKWebsiteDataStore` is read back by `currentSessionKey()`.
- Manual: on macOS 15, sign in via embedded login, confirm usage populates with
  Full Disk Access DISABLED (proves the FDA dependency is gone).

## Risks / open questions

- `WKWebsiteDataStore` persistence across relaunch requires a stable store
  identifier (macOS 14+ `WKWebsiteDataStore(forIdentifier:)`); confirm the
  session cookie survives quit/relaunch.
- claude.ai login may involve bot/CAPTCHA challenges in an embedded WebView;
  verify a normal email/Google login completes in `WKWebView`. If claude.ai
  blocks embedded WebViews, fall back to guiding CLI login and keep the honesty
  fix as the floor.
- The web usage endpoint remains undocumented; this whole path stays a
  best-effort adapter. The genuinely durable answer is an Anthropic-supported
  usage API — track but do not block on it.

## Sequencing

1. Ship the honesty fix (typed outcomes + logging + corrected caption). Low risk,
   immediately stops the misleading "sign in to Safari" message.
2. Build `ClaudeWebSessionStore` + `ClaudeWebLoginView`, wire as primary web
   source, demote Safari-file scraping to optional legacy import.
3. Fixture + integration tests; manual macOS 15 verification with FDA off.
