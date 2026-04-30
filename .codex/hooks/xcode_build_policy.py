#!/usr/bin/env python3
import json
import re
import shlex
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

XCODE_COMMAND_RE = re.compile(
    r"(^|[\s;&|()])(?:xcodebuild|xctest)([\s;&|()]|$)"
    r"|(^|[\s;&|()])swift\s+(?:build|test|package)([\s;&|()]|$)"
)

SHELL_CONTROL_TOKENS = {";", "&&", "||", "|", "(", ")"}
SHELL_WRAPPERS = {"bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"}
SAFE_INSPECTION_COMMANDS = {
    "awk",
    "cat",
    "egrep",
    "fgrep",
    "find",
    "grep",
    "head",
    "less",
    "more",
    "nl",
    "rg",
    "sed",
    "tail",
}

APPROVED_PERMISSION_VALUES_RE = re.compile(
    r"require_escalated|danger-full-access|dangerously-bypass|bypassPermissions",
    re.IGNORECASE,
)

XCODE_CACHE_REASON_RE = re.compile(
    r"xcode|deriveddata|modulecache|sourcepackages|swiftpm|\.cache/clang|clang|xctest|cache",
    re.IGNORECASE,
)


def command_from(tool_input):
    if isinstance(tool_input, str):
        return tool_input
    if isinstance(tool_input, dict):
        for key in ("command", "cmd"):
            value = tool_input.get(key)
            if isinstance(value, str):
                return value
    return ""


def basename(command_token):
    return command_token.rsplit("/", 1)[-1]


def shell_words(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    return list(lexer)


def is_shell_wrapper_exec(words, index):
    token = basename(words[index])
    if token not in SHELL_WRAPPERS:
        return False

    return any(word in {"-c", "-lc", "-ilc"} for word in words[index + 1:index + 4])


def command_after_shell_c(words, index):
    for offset in range(index + 1, min(index + 4, len(words))):
        if words[offset] in {"-c", "-lc", "-ilc"} and offset + 1 < len(words):
            return words[offset + 1]
    return ""


def command_after_env(words, index):
    cursor = index + 1
    while cursor < len(words):
        word = words[cursor]
        if word in SHELL_CONTROL_TOKENS:
            return None
        if word == "--":
            cursor += 1
            break
        if word == "-":
            return None
        if word.startswith("-"):
            cursor += 1
            continue
        if "=" in word and not word.startswith("="):
            cursor += 1
            continue
        break
    return cursor if cursor < len(words) else None


def command_word_positions(words):
    expect_command = True
    for index, word in enumerate(words):
        if word in SHELL_CONTROL_TOKENS:
            expect_command = True
            continue
        if expect_command:
            yield index
            expect_command = False


def is_swift_build_command(words, index):
    if basename(words[index]) != "swift":
        return False
    return index + 1 < len(words) and words[index + 1] in {"build", "test", "package"}


def is_xcode_command_word(words, index):
    token = basename(words[index])
    return token in {"xcodebuild", "xctest"} or is_swift_build_command(words, index)


def contains_xcode_invocation(command):
    try:
        words = shell_words(command)
    except ValueError:
        return bool(XCODE_COMMAND_RE.search(command))

    for index in command_word_positions(words):
        command_name = basename(words[index])
        if command_name in SAFE_INSPECTION_COMMANDS:
            continue
        if is_xcode_command_word(words, index):
            return True
        if command_name == "env":
            env_command_index = command_after_env(words, index)
            if env_command_index is not None and is_xcode_command_word(words, env_command_index):
                return True
        if is_shell_wrapper_exec(words, index):
            nested = command_after_shell_c(words, index)
            if nested and contains_xcode_invocation(nested):
                return True

    return False


def text_field(tool_input, *keys):
    if not isinstance(tool_input, dict):
        return ""
    return "\n".join(str(tool_input.get(key) or "") for key in keys)


def has_structured_escalation(payload, tool_input):
    values = [
        payload.get("permission_mode"),
    ]
    if isinstance(tool_input, dict):
        values.extend([
            tool_input.get("sandbox_permissions"),
            tool_input.get("sandbox_mode"),
        ])

    return any(
        isinstance(value, str) and APPROVED_PERMISSION_VALUES_RE.search(value)
        for value in values
    )


def is_repo_cwd(cwd):
    try:
        Path(cwd).resolve().relative_to(REPO_ROOT)
        return True
    except Exception:
        return False


def emit_pre_tool_deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def emit_permission_allow():
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow"
            }
        }
    }))


def handle_pre_tool_use(payload, tool_input, command):
    if has_structured_escalation(payload, tool_input):
        return

    emit_pre_tool_deny(
        "Swift/Xcode build and test commands in this repository must request approved Xcode access "
        "before running. Rerun the same command with sandbox_permissions=require_escalated and explain "
        "that it needs Xcode-managed cache access, such as DerivedData, ModuleCache, SourcePackages, "
        "SwiftPM diagnostics, or ~/.cache/clang."
    )


def handle_permission_request(tool_input, command):
    reason = text_field(tool_input, "description", "justification")
    if XCODE_CACHE_REASON_RE.search(reason):
        emit_permission_allow()


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if not is_repo_cwd(payload.get("cwd", "")):
        return 0

    tool_name = str(payload.get("tool_name", ""))
    if tool_name != "Bash":
        return 0

    tool_input = payload.get("tool_input")
    command = command_from(tool_input)
    if not command or not contains_xcode_invocation(command):
        return 0

    event_name = payload.get("hook_event_name")
    if event_name == "PreToolUse":
        handle_pre_tool_use(payload, tool_input, command)
    elif event_name == "PermissionRequest":
        handle_permission_request(tool_input, command)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
