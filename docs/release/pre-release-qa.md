# Pre-Release QA Checklist (Recommended)

Use this checklist before **any** release (patch, minor, or major).  
Goal: catch regressions early, confirm release notes/docs are accurate, and ship with a clear go/no-go decision.

## 0. Scope and Risk (5-10 min)

- [ ] Identify release scope (`last tag -> HEAD`) and list user-visible changes.
- [ ] Mark high-risk areas touched in this release (for example: parsing, indexing, windowing, onboarding, deployment, signing).
- [ ] Decide QA depth:
  - Hotfix: full automated gates + focused manual smoke.
  - Minor/Major: full automated gates + full manual smoke.

Helpful commands:

```bash
git log --oneline --decorate -n 30
git diff --name-only <LAST_TAG>..HEAD
```

## 1. Automated Gates (Required)

Run from repo root.

### 1.1 Build

- [ ] App build succeeds:

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

### 1.2 Test Suite

- [ ] Full stable suite passes:

```bash
./scripts/xcode_test_stable.sh
```

- [ ] Targeted suites for touched high-risk areas pass (examples):

```bash
./scripts/xcode_test_stable.sh \
  -only-testing:AgentSessionsTests/CodexActiveSessionsRegistryTests \
  -only-testing:AgentSessionsTests/OnboardingCoordinatorTests \
  -only-testing:AgentSessionsTests/ClaudeStatusServiceTests
```

### 1.3 Build/Runtime Warnings Sweep

- [ ] No new actionable warnings/errors in build output (ignore known destination-selection noise).

## 2. Manual Smoke (Required)

### 2.1 Core App Flows

- [ ] App launches and shows expected primary window state.
- [ ] Session list loads, search works, session selection opens transcript/session view.
- [ ] Preferences open and changed settings persist after relaunch.
- [ ] Key menu actions and keyboard shortcuts behave as expected.

### 2.2 Windowing and View Modes

- [ ] Agent Cockpit opens/focuses correctly from menu/shortcut.
- [ ] Compact/full mode toggles, pin behavior, and row actions work.
- [ ] If this release touched Image Browser, Saved Sessions, or other windows: open/close/focus each path at least once.

### 2.3 Onboarding (Always include)

- [ ] Fresh-install onboarding path behaves correctly.
- [ ] Upgrade onboarding path behaves correctly for this version policy.
- [ ] "Show Onboarding" menu action opens expected content.

### 2.4 Appearance and Accessibility Basics

- [ ] Light/Dark/System appearance toggles work.
- [ ] Text truncation/tooltips/readability are acceptable for long labels.

## 3. Stability Quick Check (Recommended)

- [ ] Let app sit idle 3-5 minutes; verify no obvious refresh churn or runaway CPU.
- [ ] Exercise refresh/search/filter loops; verify no flicker/blank state regressions.
- [ ] Verify focus switching (foreground/background/window switch) for the changed areas.

## 4. Release Content and Packaging Readiness (Required)

- [ ] `docs/CHANGELOG.md` has accurate user-visible notes under `[Unreleased]` (or release section after bump).
- [ ] `docs/summaries/YYYY-MM.md` includes concise bullets for user-visible changes.
- [ ] Deployment prerequisites in `docs/deployment.md` are satisfied.

## 5. Go/No-Go Decision (Required)

- [ ] **Go** only if all required checks above pass.
- [ ] For any failed/non-run item, record blocker + owner + ETA.

Suggested release note in your QA log:

```text
QA result: GO | NO-GO
Version: <VERSION>
Commit: <SHA>
Automated: build ✅/❌, full tests ✅/❌, targeted tests ✅/❌
Manual smoke: ✅/❌ (list any gaps)
Known risks accepted: <none or list>
```

---

Reference runbook: `docs/deployment.md`  
Deployment skill entrypoint: `.claude/skills/deploy.md`
