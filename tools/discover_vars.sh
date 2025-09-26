#!/usr/bin/env bash
set -euo pipefail

# Discover signing & build values for Agent Sessions (no secrets printed)
# Prints: Bundle ID, Team ID, Developer ID cert names, Release .app path, notarytool profile status

SCHEME="AgentSessions"
CONFIG="Release"
PROFILE="AgentSessionsNotary"

app_plist="AgentSessions/Info.plist"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_plist" 2>/dev/null || true)
dev_id_app=$(security find-identity -p codesigning -v 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}')
dev_id_installer=$(security find-identity -p codesigning -v 2>/dev/null | awk -F '"' '/Developer ID Installer/ {print $2; exit}')
team_id=$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*Developer ID Application: .* (\([A-Z0-9]\{10\}\)).*/\1/p' | head -n1)

# Build settings (do not build; only show where Release would land)
settings=$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null || true)
target_dir=$(awk '/ TARGET_BUILD_DIR / {print $3; exit}' <<<"$settings" || true)
wrapper=$(awk '/ WRAPPER_NAME / {print $3; exit}' <<<"$settings" || true)
app_path=""; if [[ -n "$target_dir" && -n "$wrapper" ]]; then app_path="$target_dir/$wrapper"; fi

echo "Bundle ID       : ${bundle_id:-com.triada.AgentSessions}"
echo "Team ID         : ${team_id:-<unknown>}"
echo "Dev ID (App)    : ${dev_id_app:-<none found>}"
echo "Dev ID (Inst.)  : ${dev_id_installer:-<none found>}"
echo "Release .app    : ${app_path:-<build Release to detect>}"
echo "Notary profile  : $PROFILE"

if xcrun notarytool whoami --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Notary whoami   : OK (profile available)"
else
  echo "Notary whoami   : Not configured"
  cat <<EOF
  Create once:
    xcrun notarytool store-credentials "$PROFILE" \\
      --apple-id "<your-apple-id@example.com>" \\
      --team-id "${team_id:-TEAMID}" \\
      --password "<app-specific-password>"
EOF
fi
