# Localization conventions

Agent Sessions uses English as its source language. Simplified Chinese,
identified as `zh-Hans`, is the planned first translation; it is not currently
supported. A locale is not considered supported until both catalogs are
complete and a human has reviewed them.

## Catalogs

- App copy belongs in `AgentSessions/Resources/Localizable.xcstrings`.
- Bundle display names and macOS permission prompts belong in
  `AgentSessions/Resources/InfoPlist.xcstrings`.
- Both catalogs declare `en` as their source language. Do not add a locale to a
  catalog until its translation is ready for review.
- CI permits the planned `zh-Hans` locale only when it is present, non-empty,
  and marked translated for every key in both catalogs. Partial locale imports
  and unreviewed locale identifiers fail validation.
- Keep catalog changes deterministic and reviewable. CI compiles catalogs into a
  temporary directory and never syncs generated extraction over committed
  translation data.

## Choosing an API

Use a localizable API at the boundary where copy enters a user-facing surface:

- Direct, one-off SwiftUI copy stays as a string literal in `Text`, `Button`,
  `Toggle`, `Label`, `Menu`, and `Window` initializers. SwiftUI treats these
  literals as `LocalizedStringKey` values and Xcode extracts them.
- Reusable views and app-owned models that carry copy use
  `LocalizedStringResource`, not an undifferentiated `String`. This preserves
  the localization key while the copy moves through the view hierarchy.
- AppKit APIs that require a resolved `String` use `String(localized:comment:)`.
  This includes alerts, menu items, notifications, tooltips, and window
  controllers.
- Use `Text(verbatim:)` and ordinary `String` for transcript content, user
  prompts, command lines, paths, IDs, raw logs, provider/product names, and
  other data that must remain byte-for-byte content.

Translation comments are required for short or ambiguous labels, destructive
actions, permission text, placeholders, interpolations, keyboard shortcuts,
and copy whose meaning depends on its surrounding surface.

## Interpolation and grammar

Keep a complete sentence or phrase in one localization unit. Do not concatenate
translated fragments to form a sentence. Counts, dates, percentages, and other
grammar-sensitive text use interpolation in a `LocalizedStringResource` or a
`String(localized:)` call so a translation can reorder the values. Use explicit
plural variants when a value changes the noun or verb.

Onboarding content is structured data: every screen and tip has a stable ID,
and title/body values are typed localizable resources. Do not derive IDs from
translated display text, and do not parse localized punctuation (for example,
splitting a tip at a colon).

## Stable identity

Displayed text is not program identity. Window routing, defaults, notification
identifiers, onboarding IDs, menu actions, and tests use stable identifiers that
do not change when a locale changes. The main window keeps its historical
SwiftUI scene ID, `Agent Sessions`, as opaque program identity for restoration
compatibility. AppKit routing uses `AgentSessionsMainWindow`; both identifiers
are separate from the localized visible title.

The product name `Agent Sessions`, provider names such as Codex and Claude,
macOS product names, CLI names, search operators, and literal commands remain
unchanged unless a future translation decision explicitly documents otherwise.

## Review and validation

Before adding `zh-Hans`:

1. Build the app and run the focused localization tests.
2. Run `scripts/validate_localization_catalogs.py` and confirm both catalogs
   compile with `xcrun xcstringstool`.
3. Check English, Simplified Chinese, and Double-Length Pseudolanguage for
   windows, menus, Preferences, onboarding, alerts, notifications, and
   accessibility labels.
4. Test counts at 0, 1, and 2, plus long Chinese strings and right-to-left-safe
   layout assumptions where relevant.
5. Confirm transcripts, paths, commands, IDs, and provider/product names remain
   verbatim.

Machine-assisted translation may prepare a catalog, but it is not linguistic
approval. The contributor or maintainer reviewing the locale owns the final
translation quality.
