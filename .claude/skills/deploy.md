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
5. **Deploy** - `SKIP_CONFIRM=1 tools/release/deploy release {VERSION}`
6. **Verify** - `tools/release/deploy verify {VERSION}`

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
- Script may produce wrong format - verify manually

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

## Recovery

If deployment fails partway through, see "Manual Deployment" and "Emergency Rollback" sections in `docs/deployment.md`.
