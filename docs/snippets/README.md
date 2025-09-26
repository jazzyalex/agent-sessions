# Snippets (Deployment & Packaging)

This folder collects practical command snippets you’ll likely reuse (DMG creation, signing, notarization, release uploads). Start with:

- dmg-deployment-snippets.md — codesign, DMG build (hdiutil / create-dmg), notarize/staple, PKG alternative, gh release.

If you want to automatically harvest snippets from your past Codex CLI sessions, use the helper script below to scan your `~/.codex/sessions` and extract lines that look like packaging commands.

## Harvest from Past Sessions (Optional)

Requires: bash, `rg` (ripgrep) recommended, `jq` optional.

```bash
./tools/extract_snippets.sh \
  --root "$HOME/.codex/sessions" \
  --out  "snippets/collected-dmg-snippets.md"
```

The output groups matches by session file and attempts to extract only likely command lines (codesign, notarytool, stapler, hdiutil, create-dmg, pkgbuild, productbuild, spctl, ditto). You can then curate and copy useful blocks into your playbook.

Note: Agent Sessions doesn’t need these to function; they’re here to accelerate a vibe-friendly release workflow.

