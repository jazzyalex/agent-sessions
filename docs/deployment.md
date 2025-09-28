# Agent Sessions Deployment Runbook

This runbook describes a flexible, Codex‑friendly process to ship a new Agent Sessions build. It pairs with the automation script `./deploy-agent-sessions.sh` for common paths while leaving room for interactive steps when needed.

## Goals
- Produce a signed, notarized DMG
- Publish it to GitHub Releases with accurate notes
- Update README and GitHub Pages download links
- Optionally update the Homebrew cask

## Preconditions
- macOS with Xcode CLT installed
- Developer ID Application certificate installed in the login keychain
- Notary profile stored in Keychain:

```bash
xcrun notarytool store-credentials AgentSessionsNotary \
  --apple-id "<your-apple-id@example.com>" \
  --team-id "<YOUR_TEAM_ID>" \
  --password "<app-specific-password>"
```

- GitHub CLI authenticated: `gh auth login`

## Versioning
- Confirm current version (`MARKETING_VERSION`) in `AgentSessions.xcodeproj/project.pbxproj`.
- Choose the release version (for example, `1.2`).

## Asset preparation
- Update screenshots:
  - `docs/assets/screenshot-V.png`
  - `docs/assets/screenshot-H.png`
- Update `docs/CHANGELOG.md` with a section for the new version.
- Review `README.md` for any copy or link adjustments.

## Automated path (recommended)

```bash
chmod +x tools/release/deploy-agent-sessions.sh
VERSION=1.2 tools/release/deploy-agent-sessions.sh
```

Script flow:
1. Shows current version and prompts for target version
2. Runs preflight checks (xcodebuild, gh, notary profile, Developer ID identity)
3. Builds, signs, notarizes, and staples the DMG
4. Updates README and website links
5. Generates release notes from `docs/CHANGELOG.md` section for the version or falls back to `git log` since the last tag
6. Creates or updates the GitHub Release and uploads assets
7. Optionally updates the local Homebrew cask if present

Environment variables (optional, set in `tools/release/.env`, not committed):

```bash
TEAM_ID=24NDRU35WD
NOTARY_PROFILE=AgentSessionsNotary
DEV_ID_APP="Developer ID Application: Your Name (24NDRU35WD)"
```

## Manual steps (when deviating from the script)
1. Build Release to `dist/` using `xcodebuild`
2. Codesign with hardened runtime
3. Create DMG with `hdiutil`
4. Notarize with `xcrun notarytool submit --wait` and staple
5. Compute SHA256 and upload DMG and checksum to GitHub Release (`gh release create|upload`)
6. Update README and website links to the new DMG URL
7. Update Homebrew cask with new `version`, `sha256`, and URL pattern

## Acceptance criteria
- DMG is stapled and passes Gatekeeper assessment on a fresh system
- GitHub Release contains DMG and `.sha256`, with correct notes
- README and website link to the exact versioned DMG
- Optional: Homebrew cask installs the new version

## Troubleshooting
- Notary profile errors: re‑run `store-credentials` with correct Apple ID, team id, and app‑specific password
- Gatekeeper says “Insufficient Context” on stapled DMG: verify notarization shows `Accepted`, and staple again
- `gh` errors: confirm `gh auth status` and token scopes include `repo` and `workflow`
