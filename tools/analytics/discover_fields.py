#!/usr/bin/env python3
"""
Session Field Discovery Script

Scans session files from Codex, Claude Code, and Gemini CLIs to catalog
all available fields, their types, frequencies, and example values.

This is a read-only analysis tool for Analytics feature planning.
"""

import json
import sys
import os
from pathlib import Path
from collections import defaultdict, Counter
from datetime import datetime
from typing import Any, Dict, List, Set, Tuple
import yaml


class FieldCatalog:
    """Tracks discovered fields across sessions"""

    def __init__(self):
        self.fields = defaultdict(lambda: {
            'type': set(),
            'count': 0,
            'total_sessions': 0,
            'examples': [],
            'always_present': True,
        })
        self.sessions_scanned = 0

    def add_field(self, path: str, value: Any, session_num: int):
        """Record a field occurrence"""
        field_info = self.fields[path]
        field_info['count'] += 1
        field_info['type'].add(type(value).__name__)

        # Store up to 3 diverse examples
        if len(field_info['examples']) < 3:
            example_str = str(value)
            if len(example_str) > 200:
                example_str = example_str[:200] + '...'
            if example_str not in field_info['examples']:
                field_info['examples'].append(example_str)

    def mark_session(self):
        """Mark a new session scanned"""
        self.sessions_scanned += 1
        # Update always_present flags
        for path, info in self.fields.items():
            if info['total_sessions'] < self.sessions_scanned:
                info['always_present'] = False
            info['total_sessions'] = self.sessions_scanned

    def to_dict(self) -> Dict:
        """Convert to serializable dict"""
        result = {}
        for path, info in sorted(self.fields.items()):
            result[path] = {
                'types': list(info['type']),
                'frequency': f"{info['count']}/{self.sessions_scanned} sessions",
                'always_present': info['always_present'],
                'examples': info['examples'][:3],
            }
        return result


def scan_json_object(obj: Any, catalog: FieldCatalog, session_num: int, prefix: str = ''):
    """Recursively scan JSON object and catalog fields"""
    if isinstance(obj, dict):
        for key, value in obj.items():
            path = f"{prefix}.{key}" if prefix else key
            catalog.add_field(path, value, session_num)

            # Recurse into nested structures
            if isinstance(value, (dict, list)):
                scan_json_object(value, catalog, session_num, path)

    elif isinstance(obj, list):
        for i, item in enumerate(obj[:5]):  # Sample first 5 items
            scan_json_object(item, catalog, session_num, f"{prefix}[]")


def discover_codex_sessions(limit: int = 20) -> FieldCatalog:
    """Scan Codex JSONL sessions"""
    print(f"\n=== Discovering Codex Sessions ===")

    # Find Codex sessions root
    codex_home = os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex'))
    sessions_root = Path(codex_home) / 'sessions'

    if not sessions_root.exists():
        print(f"Codex sessions not found at: {sessions_root}")
        return FieldCatalog()

    # Find rollout-*.jsonl files
    session_files = list(sessions_root.rglob('rollout-*.jsonl'))
    print(f"Found {len(session_files)} Codex session files")

    # Sample diverse sessions (small, medium, large)
    session_files.sort(key=lambda p: p.stat().st_size)
    sample_files = []

    # Take some small, medium, large
    if len(session_files) > 0:
        sample_files.append(session_files[0])  # Smallest
    if len(session_files) > limit // 2:
        sample_files.append(session_files[len(session_files) // 2])  # Medium
    if len(session_files) > 1:
        sample_files.append(session_files[-1])  # Largest

    # Add recent sessions
    recent = sorted(session_files, key=lambda p: p.stat().st_mtime, reverse=True)[:limit]
    sample_files.extend(recent)
    sample_files = list(set(sample_files))[:limit]

    catalog = FieldCatalog()

    for i, session_file in enumerate(sample_files):
        print(f"Scanning [{i+1}/{len(sample_files)}]: {session_file.name} ({session_file.stat().st_size} bytes)")

        try:
            with open(session_file, 'r') as f:
                for line_num, line in enumerate(f):
                    if not line.strip():
                        continue
                    try:
                        obj = json.loads(line)
                        scan_json_object(obj, catalog, i, prefix='')
                    except json.JSONDecodeError as e:
                        print(f"  Warning: Line {line_num} parse error: {e}")

            catalog.mark_session()

        except Exception as e:
            print(f"  Error reading {session_file}: {e}")

    print(f"Scanned {catalog.sessions_scanned} Codex sessions")
    print(f"Found {len(catalog.fields)} unique field paths")

    return catalog


def discover_claude_sessions(limit: int = 20) -> FieldCatalog:
    """Scan Claude Code sessions"""
    print(f"\n=== Discovering Claude Code Sessions ===")

    claude_root = Path.home() / '.claude'

    if not claude_root.exists():
        print(f"Claude directory not found at: {claude_root}")
        return FieldCatalog()

    # Find .jsonl and .ndjson files
    session_files = list(claude_root.rglob('*.jsonl')) + list(claude_root.rglob('*.ndjson'))

    # Exclude very large files for now (history.jsonl can be huge)
    session_files = [f for f in session_files if f.stat().st_size < 50 * 1024 * 1024]  # < 50MB

    print(f"Found {len(session_files)} Claude session files")

    # Sample diverse sessions
    session_files.sort(key=lambda p: p.stat().st_size)
    sample_files = session_files[:limit]

    catalog = FieldCatalog()

    for i, session_file in enumerate(sample_files):
        print(f"Scanning [{i+1}/{len(sample_files)}]: {session_file.name} ({session_file.stat().st_size} bytes)")

        try:
            with open(session_file, 'r') as f:
                for line_num, line in enumerate(f):
                    if not line.strip():
                        continue
                    try:
                        obj = json.loads(line)
                        scan_json_object(obj, catalog, i, prefix='')
                    except json.JSONDecodeError as e:
                        print(f"  Warning: Line {line_num} parse error: {e}")

            catalog.mark_session()

        except Exception as e:
            print(f"  Error reading {session_file}: {e}")

    print(f"Scanned {catalog.sessions_scanned} Claude sessions")
    print(f"Found {len(catalog.fields)} unique field paths")

    return catalog


def discover_gemini_sessions(limit: int = 20) -> FieldCatalog:
    """Scan Gemini sessions"""
    print(f"\n=== Discovering Gemini Sessions ===")

    gemini_root = Path.home() / '.gemini' / 'tmp'

    if not gemini_root.exists():
        print(f"Gemini sessions not found at: {gemini_root}")
        return FieldCatalog()

    # Find session-*.json files
    session_files = list(gemini_root.rglob('session-*.json'))
    print(f"Found {len(session_files)} Gemini session files")

    # Sample diverse sessions
    session_files.sort(key=lambda p: p.stat().st_size)
    sample_files = session_files[:limit]

    catalog = FieldCatalog()

    for i, session_file in enumerate(sample_files):
        print(f"Scanning [{i+1}/{len(sample_files)}]: {session_file.name} ({session_file.stat().st_size} bytes)")

        try:
            with open(session_file, 'r') as f:
                obj = json.load(f)
                scan_json_object(obj, catalog, i, prefix='')

            catalog.mark_session()

        except Exception as e:
            print(f"  Error reading {session_file}: {e}")

    print(f"Scanned {catalog.sessions_scanned} Gemini sessions")
    print(f"Found {len(catalog.fields)} unique field paths")

    return catalog


def main():
    """Main discovery pipeline"""
    print("Session Field Discovery Tool")
    print("=" * 60)

    # Discover fields from each CLI
    codex_catalog = discover_codex_sessions(limit=20)
    claude_catalog = discover_claude_sessions(limit=20)
    gemini_catalog = discover_gemini_sessions(limit=20)

    # Generate combined report
    output = {
        'generated_at': datetime.now().isoformat(),
        'summary': {
            'codex_sessions_scanned': codex_catalog.sessions_scanned,
            'codex_unique_fields': len(codex_catalog.fields),
            'claude_sessions_scanned': claude_catalog.sessions_scanned,
            'claude_unique_fields': len(claude_catalog.fields),
            'gemini_sessions_scanned': gemini_catalog.sessions_scanned,
            'gemini_unique_fields': len(gemini_catalog.fields),
        },
        'codex_fields': codex_catalog.to_dict(),
        'claude_fields': claude_catalog.to_dict(),
        'gemini_fields': gemini_catalog.to_dict(),
    }

    # Write to output file
    output_file = Path(__file__).parent.parent.parent / 'docs' / 'analytics' / 'field-catalog.yaml'
    output_file.parent.mkdir(parents=True, exist_ok=True)

    with open(output_file, 'w') as f:
        yaml.dump(output, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    print(f"\n{'=' * 60}")
    print(f"Field catalog written to: {output_file}")
    print(f"\nSummary:")
    print(f"  Codex:  {codex_catalog.sessions_scanned} sessions, {len(codex_catalog.fields)} fields")
    print(f"  Claude: {claude_catalog.sessions_scanned} sessions, {len(claude_catalog.fields)} fields")
    print(f"  Gemini: {gemini_catalog.sessions_scanned} sessions, {len(gemini_catalog.fields)} fields")

    return 0


if __name__ == '__main__':
    sys.exit(main())
