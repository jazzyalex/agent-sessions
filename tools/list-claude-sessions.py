#!/usr/bin/env python3
"""
List Claude Code sessions with all fields shown in Agent Sessions app.
Discovers JSONL files in ~/.claude/ and extracts session metadata.
"""

import json
import os
import glob
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, Any, List
from collections import defaultdict

HOME = Path.home()
CLAUDE_PATHS = [
    HOME / ".claude" / "**" / "*.jsonl",
    HOME / ".claude" / "**" / "*.ndjson",
    HOME / "claude-logs" / "**" / "*.jsonl",
]

class ClaudeSession:
    def __init__(self, filepath: Path):
        self.filepath = filepath
        self.id = None
        self.start_time = None
        self.end_time = None
        self.model = None
        self.event_count = 0
        self.events = []
        self.cwd = None
        self.title = None
        self.repo_name = None
        self.git_branch = None

    def parse(self, max_events: int = 50):
        """Parse JSONL file and extract session metadata"""
        try:
            with open(self.filepath, 'r', encoding='utf-8', errors='replace') as f:
                for idx, line in enumerate(f):
                    line = line.strip()
                    if not line:
                        continue

                    self.event_count += 1

                    # Only parse first N events for performance
                    if idx >= max_events:
                        continue

                    try:
                        event = json.loads(line)
                        self.events.append(event)

                        # Extract session_id
                        if not self.id:
                            self.id = event.get('session_id') or event.get('id')
                            if 'payload' in event:
                                self.id = self.id or event['payload'].get('session_id')

                        # Extract timestamps
                        ts = self._extract_timestamp(event)
                        if ts:
                            if not self.start_time or ts < self.start_time:
                                self.start_time = ts
                            if not self.end_time or ts > self.end_time:
                                self.end_time = ts

                        # Extract model
                        if not self.model:
                            self.model = event.get('model')
                            if 'payload' in event:
                                self.model = self.model or event['payload'].get('model')

                        # Extract cwd
                        if not self.cwd:
                            self.cwd = event.get('cwd')
                            if 'payload' in event:
                                self.cwd = self.cwd or event['payload'].get('cwd')
                            # Check in text for <cwd>
                            text = event.get('text') or event.get('content', '')
                            if '<cwd>' in text and '</cwd>' in text:
                                start = text.find('<cwd>') + 5
                                end = text.find('</cwd>')
                                self.cwd = text[start:end].strip()

                        # Extract title (first user message)
                        if not self.title:
                            event_type = event.get('type')
                            is_meta = event.get('isMeta', False)

                            # Claude Code format: type="user" with nested message.content
                            if event_type == 'user' and not is_meta:
                                text = None
                                # Try nested message object first
                                if 'message' in event and isinstance(event['message'], dict):
                                    content = event['message'].get('content')
                                    # Handle list of content blocks (multimodal)
                                    if isinstance(content, list):
                                        text = ' '.join(str(item.get('text', '')) if isinstance(item, dict) else str(item) for item in content)
                                    else:
                                        text = content
                                # Fallback to direct content
                                if not text:
                                    content = event.get('content') or event.get('text')
                                    if isinstance(content, list):
                                        text = ' '.join(str(item.get('text', '')) if isinstance(item, dict) else str(item) for item in content)
                                    else:
                                        text = content

                                if text and isinstance(text, str) and len(text.strip()) > 0:
                                    # Clean up and truncate
                                    text = ' '.join(text.strip().split())
                                    if len(text) > 200:
                                        text = text[:200]
                                    # Skip scaffolding and command markers
                                    lower = text.lower()
                                    skip_patterns = [
                                        'you are an expert', 'you are a helpful', 'act as a',
                                        '<command-name>', 'caveat:', '<local-command'
                                    ]
                                    if not any(pattern in lower for pattern in skip_patterns):
                                        self.title = text

                        # Extract git branch
                        if not self.git_branch:
                            self.git_branch = event.get('git_branch') or event.get('branch')
                            if 'repo' in event and isinstance(event['repo'], dict):
                                self.git_branch = self.git_branch or event['repo'].get('branch')

                    except json.JSONDecodeError:
                        continue

        except Exception as e:
            print(f"Error reading {self.filepath}: {e}")
            return False

        # Derive repo name from cwd
        if self.cwd:
            self.repo_name = Path(self.cwd).name

        # Fallback session ID from filename
        if not self.id:
            self.id = self.filepath.stem[:12]

        # Fallback title
        if not self.title:
            self.title = "No prompt"

        return True

    def _extract_timestamp(self, event: Dict[str, Any]) -> Optional[datetime]:
        """Extract timestamp from event, trying multiple keys"""
        ts_keys = ['timestamp', 'time', 'ts', 'created', 'created_at', 'datetime', 'date']

        # Check top level
        for key in ts_keys:
            if key in event:
                return self._parse_timestamp(event[key])

        # Check payload
        if 'payload' in event:
            for key in ts_keys:
                if key in event['payload']:
                    return self._parse_timestamp(event['payload'][key])

        return None

    def _parse_timestamp(self, value) -> Optional[datetime]:
        """Parse timestamp value (int, float, or string)"""
        if isinstance(value, (int, float)):
            # Handle epoch seconds, milliseconds, microseconds
            if value > 1e14:  # microseconds
                value = value / 1_000_000
            elif value > 1e11:  # milliseconds
                value = value / 1_000
            try:
                return datetime.fromtimestamp(value)
            except:
                return None
        elif isinstance(value, str):
            # Try ISO format
            try:
                return datetime.fromisoformat(value.replace('Z', '+00:00'))
            except:
                return None
        return None

    def modified_at(self) -> datetime:
        """Get effective modified time (prefer end_time, fallback to file mtime)"""
        if self.end_time:
            return self.end_time
        if self.start_time:
            return self.start_time
        return datetime.fromtimestamp(self.filepath.stat().st_mtime)

    def to_row(self) -> Dict[str, Any]:
        """Format as row for display"""
        return {
            'title': self.title or 'No prompt',
            'modified': self.modified_at().strftime('%Y-%m-%d %H:%M:%S'),
            'project': self.repo_name or '—',
            'msgs': f"~{self.event_count}" if self.event_count > 0 else '0',
            'model': self.model or '—',
            'branch': self.git_branch or '—',
            'cwd': self.cwd or '—',
            'file': str(self.filepath.relative_to(HOME)),
            'id': (self.id or '')[:12],
        }


def find_sessions() -> List[Path]:
    """Find all Claude Code session files"""
    files = []
    for pattern in CLAUDE_PATHS:
        files.extend(glob.glob(str(pattern), recursive=True))
    return [Path(f) for f in sorted(set(files), key=lambda x: os.path.getmtime(x), reverse=True)]


def main():
    print("🔍 Scanning for Claude Code sessions...\n")

    files = find_sessions()
    print(f"📁 Found {len(files)} JSONL files\n")

    if not files:
        print("No Claude Code session files found in:")
        for pattern in CLAUDE_PATHS:
            print(f"  - {pattern}")
        return

    sessions = []
    for filepath in files:
        session = ClaudeSession(filepath)
        if session.parse():
            sessions.append(session)

    print(f"✅ Parsed {len(sessions)} sessions\n")
    print("=" * 120)

    # Display table
    if sessions:
        rows = [s.to_row() for s in sessions]

        # Print header
        print(f"{'Title':<40} {'Modified':<20} {'Proj':<15} {'Msgs':<6} {'Model':<20} {'Branch':<15}")
        print("-" * 120)

        # Print rows
        for row in rows:
            title = row['title'][:38] + '..' if len(row['title']) > 40 else row['title']
            project = row['project'][:13] + '..' if len(row['project']) > 15 else row['project']
            model = row['model'][:18] + '..' if len(row['model']) > 20 else row['model']
            branch = row['branch'][:13] + '..' if len(row['branch']) > 15 else row['branch']

            print(f"{title:<40} {row['modified']:<20} {project:<15} {row['msgs']:<6} {model:<20} {branch:<15}")

        print("-" * 120)
        print(f"\n📊 Summary:")
        print(f"  Total sessions: {len(sessions)}")
        print(f"  With model: {sum(1 for s in sessions if s.model)}")
        print(f"  With cwd: {sum(1 for s in sessions if s.cwd)}")
        print(f"  With title: {sum(1 for s in sessions if s.title and s.title != 'No prompt')}")

        # Show sample paths
        print(f"\n📂 Sample file locations:")
        for s in sessions[:3]:
            print(f"  - {s.filepath.relative_to(HOME)}")
            if s.id:
                print(f"    Session ID: {s.id[:12]}")
            if s.cwd:
                print(f"    Working dir: {s.cwd}")

        # Show sample raw events from first session
        if sessions and sessions[0].events:
            print(f"\n🔬 Sample events from first session (for debugging):")
            print(f"   File: {sessions[0].filepath.name}")
            for idx, event in enumerate(sessions[0].events[:3]):
                print(f"\n   Event {idx + 1}:")
                # Show relevant keys
                keys_to_show = ['role', 'type', 'text', 'content', 'message', 'model', 'timestamp', 'cwd', 'session_id']
                for key in keys_to_show:
                    if key in event:
                        value = event[key]
                        if isinstance(value, str) and len(value) > 100:
                            value = value[:100] + '...'
                        print(f"     {key}: {value}")
                # Show all top-level keys
                print(f"     [All keys: {', '.join(event.keys())}]")


if __name__ == '__main__':
    main()
