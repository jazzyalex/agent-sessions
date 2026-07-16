# Changelog

The changelog lives at **[docs/CHANGELOG.md](docs/CHANGELOG.md)**.

That is the single source of truth: `tools/release/deploy bump` writes it, and the
Sparkle and GitHub release notes are generated from it. This file used to be a
full second copy kept in sync by hand — which silently stopped happening, so it
missed the 4.4 release entirely and drifted from the real changelog. It is a
pointer now so the two can never disagree again.
