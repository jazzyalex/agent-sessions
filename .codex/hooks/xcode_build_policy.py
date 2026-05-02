#!/usr/bin/env python3
"""Compatibility shim for already-running Codex sessions with cached hook config.

Repo-local hook config has been removed. Existing Codex processes may still try
to execute this path until they restart; exit silently so shell commands keep
working during that transition.
"""

raise SystemExit(0)
