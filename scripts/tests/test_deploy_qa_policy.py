from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
DEPLOY_SOURCE = (REPO / "tools" / "release" / "deploy").read_text(encoding="utf-8")
WORKFLOW_SOURCE = (REPO / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")


def test_qa_rerun_invalidates_old_stamp_before_writing_new_one():
    qa_core = DEPLOY_SOURCE.index("run_release_qa_core()")
    preflight = DEPLOY_SOURCE.index('green "✓ Clean main synced with origin/main"', qa_core)
    invalidation = DEPLOY_SOURCE.index("  invalidate_qa_stamp\n", preflight)
    write = DEPLOY_SOURCE.index('write_qa_stamp "$VERSION" "$head" "$started_at"', preflight)

    assert preflight < invalidation < write


def test_bump_requires_target_version_qa_before_mutating_release_metadata():
    bump = DEPLOY_SOURCE.index("cmd_bump()")
    required_qa = DEPLOY_SOURCE.index('require_qa_stamp "$NEW_VERSION"', bump)
    version_mutation = DEPLOY_SOURCE.index('safe_version_bump "AgentSessions.xcodeproj/project.pbxproj"', bump)

    assert required_qa < version_mutation


def test_ci_selects_xcode_before_localization_validation():
    selection = WORKFLOW_SOURCE.index("Select and verify Xcode toolchain")
    localization = WORKFLOW_SOURCE.index("Localization catalog validation")

    assert selection < localization
