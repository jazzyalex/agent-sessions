# Control file: .codex-review-control.md

This workflow polls a control file between rounds and during in-flight heartbeat checks.

Default location: `.codex-review-control.md` at repo root.

## Supported directives (v1)

### status
```
status: pause
```
Valid values: `pause | resume | stop`

- `pause`: the loop waits (polls every ~2s) until status becomes `resume` or `stop`.
- `stop`: exits gracefully, leaving artifacts.
  If set during an active review/fix command, the loop terminates that command and exits.

### review_model
Overrides the review selector for the next round.

You can set:
- a reasoning effort (recommended):
  ```
  review_model: xhigh
  ```
- a model id:
  ```
  review_model: gpt-5.3-codex
  ```
- both model + effort:
  ```
  review_model: gpt-5.3-codex@xhigh
  ```

### fix_model
Same syntax as `review_model`, applied to the fix step.

### scope
Override what diff the review runs against:

```
scope: uncommitted
```

or

```
scope: base:main
```

or

```
scope: commit:abcdef1234
```

### append_context
Extra text appended to the next fix prompt.

One line:
```
append_context: Please keep diffs minimal and don't change public APIs.
```

Multi-line (YAML-ish):
```
append_context: |
  Please keep diffs minimal.
  Prefer adding tests over refactoring.
  Don't touch unrelated files.
```

## Example file

```md
# .codex-review-control.md

status: resume
scope: uncommitted
review_model: xhigh
fix_model: gpt-5.3-codex@high

append_context: |
  Keep changes minimal.
  If a change affects behavior, add/adjust tests accordingly.
```

## Auth-related behavior (not control-file driven)

The loop now performs auth preflight and fail-fast detection for auth errors like
`refresh_token_reused`. This is configured via environment variables, not control-file keys:

- `AUTH_FAILURE_RETRIES` (default `1`)
- `AUTH_SCAN_TAIL_LINES` (default `200`)
