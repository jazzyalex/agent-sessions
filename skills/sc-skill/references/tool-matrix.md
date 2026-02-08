# Screenshot Tool Matrix

## Decision Summary

- Primary for macOS app UI automation: `Peekaboo`.
- Fallback for minimal dependencies and fast local capture: native `screencapture` + `osascript`.
- Domain-specific companions:
- iOS simulator: `xcrun simctl io ... screenshot`.
- Web UI flows: Playwright screenshots.
- App Store/device marketing pipelines: fastlane `snapshot` + optional `frameit`.

Note: This recommendation is an inference from capabilities in official docs and local runtime behavior, not a claim that one tool is universally best.

## Matrix

| Tool | Best Use | Strengths | Tradeoffs |
|---|---|---|---|
| Peekaboo | Desktop app end-to-end scripted captures | App/window/menu automation + capture in one workflow | Extra dependency; some modes may need tuning |
| `screencapture` + `osascript` | Local deterministic fallback | Built into macOS, fast, scriptable | Less semantic UI control than dedicated automation layers |
| `xcrun simctl io screenshot` | iOS/tvOS/watchOS simulator screenshots | First-party, CI-friendly simulator capture | Simulator-only |
| Playwright (`page.screenshot`) | Web app screenshot testing/docs | Stable browser automation and screenshot APIs | Browser scope only |
| fastlane `snapshot`/`frameit` | Localized/app-store style screenshot pipeline | Built for repeatable marketing delivery | Heavier setup; mobile-centric workflows |
| CleanShot X / Shottr | Manual polish and annotation | Excellent manual capture/edit UX | Not ideal as primary deterministic automation engine |

## Source Notes

- Native macOS capture and scripting behavior is documented in local man pages:
- `man screencapture`
- `man osascript`

- Apple simulator screenshot documentation:
- https://developer.apple.com/documentation/xcode/simctl

- Playwright screenshots:
- https://playwright.dev/docs/screenshots

- fastlane screenshot pipelines:
- https://docs.fastlane.tools/getting-started/ios/screenshots/
- https://docs.fastlane.tools/actions/frameit/

- CleanShot X URL schemes:
- https://cleanshot.com/support-url-scheme

- Shottr URL actions:
- https://shottr.cc/kb/url-actions/
