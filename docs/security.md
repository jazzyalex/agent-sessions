# Security (Agent Sessions)

Agent Sessions is a local-first app. Session data stays on your Mac and is not sent to a server.

## Data access model
- The app reads session logs from local folders you choose (or the default CLI locations).
- The app may build a local index/database to enable search and navigation.

## Network activity
- The app does not include telemetry, analytics, or remote logging.
- The only network activity is optional update checking (Sparkle), if enabled.

## Update integrity (Sparkle)
- Update checks use Sparkle.
- Updates are signed (EdDSA signatures generated via Sparkle `generate_appcast`).
- The appcast is served over HTTPS.

## Reporting
If you believe you have found a security issue, contact `jazzyalex@gmail.com` with details and reproduction steps.
