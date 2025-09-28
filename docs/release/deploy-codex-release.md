# Agent Sessions — Release & Deployment Guide

This guide and script help you ship a new Agent Sessions DMG to GitHub Releases, update docs, and (optionally) update the Homebrew cask. No secrets are stored in the repo.

## Prerequisites

- Xcode and command line tools (`xcodebuild`, `notarytool`) installed
- Developer ID Application certificate in your login keychain
- Notary profile stored in keychain (once):

```bash
xcrun notarytool store-credentials AgentSessionsNotary \
  --apple-id "<your-apple-id@example.com>" \
  --team-id "<YOUR_TEAM_ID>" \
  --password "<app-specific-password>"
```

- GitHub CLI authenticated:

```bash
gh auth login
```

## Optional local defaults (no secrets in git)

Create `tools/release/.env` (gitignored) to avoid retyping values:

```bash
TEAM_ID=24NDRU35WD
NOTARY_PROFILE=AgentSessionsNotary
DEV_ID_APP="Developer ID Application: Your Name (24NDRU35WD)"
```

## Update assets first (recommended)

- Export fresh screenshots to `docs/assets/screenshot-V.png` and `docs/assets/screenshot-H.png`.
- Update README sections if needed.

## Run the deployment helper

```bash
chmod +x tools/release/deploy-agent-sessions.sh
VERSION=1.2 tools/release/deploy-agent-sessions.sh
```

You’ll be prompted to confirm key settings before the build starts. The script:

1) Pre-checks: `xcodebuild`, `gh`, Notary profile, Developer ID identity
2) Builds, signs, notarizes, staples the DMG (via `build_sign_notarize_release.sh`)
3) Updates README and docs site download links to the new version
4) Creates/updates the GitHub Release and uploads DMG + SHA256 (auto-parses notes from docs/CHANGELOG.md section for the version; falls back to git log since last tag)
5) Optionally updates local Homebrew cask if the tap is present

## Homebrew cask

If you maintain the `jazzyalex/homebrew-agent-sessions` tap locally, the script updates `Casks/agent-sessions.rb` and pushes. If not, edit and push that repo separately with the new `version`, `sha256`, and DMG file name pattern.

## Secrets handling

- No tokens or passwords are stored in the repo.
- Notary credentials live in your Keychain via `notarytool store-credentials`.
- `gh` uses your system keychain or token; no token written to this repo.
- Optional local defaults file `tools/release/.env` is gitignored and should not include passwords; it’s just convenience for `TEAM_ID`, `NOTARY_PROFILE`, `DEV_ID_APP`.

## Troubleshooting

- “codesign valid but does not seem to be an app”: harmless when verifying—continue to DMG notarization.
- Notary profile errors: re-run `xcrun notarytool store-credentials ...` with correct Apple ID, team, and app-specific password.
- `gh` errors: run `gh auth login` and ensure repo permissions include `repo` and `workflow` scopes.
