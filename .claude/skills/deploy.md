# Deployment Skill (Agent Sessions)

This skill guides Claude through deploying Agent Sessions. The technical runbook is `docs/deployment.md`.

## Before Starting

**Ask the user:**
1. What version? (e.g., "2.9" - never trailing ".0")
2. New agents or major features to highlight?

## Workflow Summary

See `docs/deployment.md` for detailed commands. High-level flow:

1. **Prepare CHANGELOG** - Write clean release notes (see guidelines below)
2. **Bump version** - Update project.pbxproj + CHANGELOG
3. **Update docs** - README.md + docs/index.html (see checklist below)
4. **Commit and push**
5. **Dry-run** - `tools/release/deploy release {VERSION} --dry-run` (preview what will happen)
6. **Deploy** - `tools/release/deploy release {VERSION}` (runs validation automatically)
7. **Verify** - `tools/release/deploy verify {VERSION}`

## Pre-Deployment Validation

The deploy script now runs `tools/release/validate-release.sh` automatically before deployment. This checks:

- Version format (warns on trailing .0)
- README.md: download links, "What's New" sections, agent mentions
- docs/index.html: download links, title, meta tags, agent mentions
- docs/CHANGELOG.md: version section with date and content
- Agent list consistency (all 5 agents mentioned)

**Exit codes:** 0 = pass, 1 = warnings (confirm to proceed), 2 = errors (cannot deploy)

To run validation manually:
```bash
tools/release/validate-release.sh 2.9
```

## Documentation Checklist

**Update BEFORE deploying** - these are often forgotten:

### README.md
- [ ] Download link and button text: version number
- [ ] Overview paragraph: all 5 agents listed
- [ ] "What's New in {VERSION}" section added
- [ ] "What's New" for ALL intermediate versions (don't skip 2.7, 2.8 when releasing 2.9!)
- [ ] Core Features → Unified Interface: all agents
- [ ] Local, Private & Safe: all session paths (including new agents)

### docs/index.html
- [ ] `<title>` tag: all agents
- [ ] All meta tags (og:description, twitter:title, twitter:description)
- [ ] Download button href and text
- [ ] Hero `<h1>` and intro paragraph: all agents
- [ ] Feature cards: new features added

## Release Notes Guidelines

**User-facing only. 10 items max.**

### Bad (Too Verbose)
- "Fixed onboarding slide 2 layout" → implementation detail
- "Refined agents tour step" → part of building the feature
- "Resolved Swift 6 actor isolation" → invisible to users
- Multiple items about same feature → consolidate!

### Good (Concise)
- "Onboarding Tours: Interactive onboarding for new installs"
- "Copilot CLI Support: Full session browser integration"
- "Saved Sessions: Archive actions now work reliably"

### Rules
1. One line per feature - consolidate related items
2. Don't list fixes to features introduced in SAME release
3. No implementation details (Swift, actor isolation, refactoring)
4. User perspective: what changed for them

## Common Pitfalls

### Version Format
- **Wrong**: 2.9.0, 2.10.0
- **Right**: 2.9, 2.10
- The `bump-version.sh` script now preserves input format by default
- Use `--format two-part` or `--format three-part` to override

### Stale Agent Lists
When adding new agent, update 10+ places:
- README: overview paragraph, Core Features (Unified Interface, Unified Search), Local & Private paths list, download links
- index.html: `<title>`, og:description, og:title, twitter:title, twitter:description, hero `<h1>`, intro paragraph, feature cards

### Missing Intermediate Versions
If README has "What's New in 2.6" but releasing 2.9:
- Add 2.7 section (Color View)
- Add 2.8 section (OpenCode support)
- Add 2.9 section

### Notarization Failures
If JSON parsing fails but upload succeeded:
- Check log file for submission ID
- `xcrun notarytool info {ID} --keychain-profile AgentSessionsNotary`
- If "Accepted", continue manually (see deployment.md)

### Verbose Release Notes
Signs of problem:
- More than 15 items
- Multiple bullets about same feature
- Implementation details mentioned
- Listing fixes for bugs you introduced in this release

## Post-Deployment Verification

1. GitHub Release has DMG + SHA256
2. Appcast shows correct version
3. DMG downloadable
4. README + index.html links correct
5. All meta tags current
6. Test Sparkle update if possible

## Dry-Run Mode

Preview what deployment would do without making changes:

```bash
tools/release/deploy release 2.9 --dry-run
```

This runs validation and shows all steps that would be performed. Useful for:
- Verifying documentation is ready
- Checking version format is correct
- Understanding the deployment pipeline

## Recovery

If deployment fails partway through, see "Manual Deployment" and "Emergency Rollback" sections in `docs/deployment.md`.

## Post-Deployment Validation

The deployment script now validates both appcast and Homebrew cask after generation:

**Appcast validation:**
- sparkle:shortVersionString matches VERSION
- sparkle:version (build number) present and > previous
- description element has content (prevents Sparkle UI hang)
- sparkle:edSignature present
- enclosure URL format correct

**Homebrew cask validation:**
- version matches VERSION
- SHA256 matches computed DMG hash
- URL format correct
