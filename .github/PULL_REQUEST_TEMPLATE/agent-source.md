## Agent source

- Agent:
- Tested agent version:
- Agent Sessions base commit:
- Official upstream project:
- Session producer/surface: CLI / IDE / desktop / daemon / shared store
- Local storage format and default path:

## Format evidence

- Fixture paths:
- Fixture provenance: synthetic / sanitized local capture
- Stable session identity:
- Update and deletion behavior:
- Private-data review performed by:

## Capability matrix

| Capability | Verified / unsupported / untested | Evidence |
|---|---|---|
| Transcript text | | |
| Tool calls and results | | |
| Reasoning | | |
| Images | | |
| Subagents | | |
| Project metadata | | |
| Deleted-session recovery | | |
| Resume command | | |

## Implementation

- [ ] Discovery and custom-root behavior use injected filesystem and home-directory seams.
- [ ] Parser has positive, malformed, and unsupported-format fixtures.
- [ ] Persisted keys, source values, and archive paths are explicit and stable.
- [ ] Search and Analytics behavior are covered.
- [ ] Preferences, filters, transcript host, and capability gates are covered.
- [ ] Shared-database enumeration distinguishes failure from authoritative emptiness, if applicable.
- [ ] Public documentation labels every capability consistently as verified, unsupported, or untested and states the evidence limits.
- [ ] No real transcript, production database, secret, account identifier, private path, private repository name, private remote URL, or URL copied from session data is committed.

## Stewardship

- [ ] I'm willing to be pinged a few times a year to re-verify this agent's format (become its steward). About 10 minutes, using my own installation. No commit rights, no code. See [STEWARDS.md](../../STEWARDS.md).

## Verification

```text
git diff --check:

Debug build:

./scripts/xcode_test_stable.sh:
```

## Limitations and follow-up

Describe every known unsupported schema variant, unverified capability, or environment you could not test.
