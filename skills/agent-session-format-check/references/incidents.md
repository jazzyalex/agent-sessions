# Format-check reference: incidents

The [runbook](../SKILL.md) governs authority and run order. Historical incidents below
explain the checks; they do not authorize sign-ins, purchases, commits or releases.

## 1c  When an Agent Cannot Produce a Session At All

Some agents are blocked for reasons no driver can fix, and the distinction matters
because it decides whether there is engineering work to do:

- **Fixable, ours** — a broken install. OpenCode sat at `installed=unknown` with an
  `Exec format error` that read like a driver bug; `/opt/homebrew/bin/opencode` was
  actually the npm package's *shell stub*, because its postinstall never ran. Run
  `file $(which <agent>)` before suspecting anything schema-shaped.
- **Fixable, theirs** — a broken agent config. OpenClaw and Hermes both fail on borrowed
  backends that are misconfigured in the user's own environment (§ledger 2026-08-13).
- **Not fixable by us** — the account or plan is gone. Qwen's OAuth free tier was
  discontinued **2026-04-15**; `qwen -p` returns "Run /auth to switch to Coding Plan,
  OpenRouter, Fireworks AI, or another provider," and `qwen auth` is itself "(removed)"
  in 0.21.x. No driver, re-login, or fixture can produce a session. Record the verdict
  honestly as `blocked_stale_sample`, say why in the matrix, and stop — it is a billing
  decision for the maintainer, not a task. What you *can* still do is a source review:
  diff the writer and reader between the last reviewed tag and the installed one
  (QwenLM/qwen-code `chatRecordingService.ts`, `transcript-records.ts`,
  `sessionService.ts`, `session-transcript-reader.ts`) and mirror changed reader rules
  with synthetic fixtures kept out of `evidence_fixtures`. The 2026-10-21 review of
  0.22.3 → 0.25.3 found four such rules. Record it as "source-reviewed through X", never
  as a ceiling bump.

Do not let category three masquerade as category one. A missing driver looks like
engineering work right up until you try to authenticate.

---
