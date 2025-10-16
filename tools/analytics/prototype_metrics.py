#!/usr/bin/env python3
"""
Prototype Metrics Calculator

Tests sample metric calculations on real session data to demonstrate
what analytics are possible with current data.

Maps to the 4 analytics scopes:
1. Total Analytics - aggregate metrics across sessions
2. By-Project Analytics - metrics per project/repo
3. Inter-Agent Comparison - comparative metrics between CLIs
4. Human Developer Performance - developer behavior patterns
"""

import json
import sys
import os
from pathlib import Path
from collections import defaultdict, Counter
from datetime import datetime, timedelta
from typing import Any, Dict, List, Set, Tuple, Optional
import re


class SessionMetrics:
    """Calculates metrics from session data"""

    def __init__(self):
        self.sessions = []
        self.by_agent = defaultdict(list)
        self.by_project = defaultdict(list)

    def add_session(self, session: Dict):
        """Add a session for analysis"""
        self.sessions.append(session)

        agent = session.get('agent', 'unknown')
        self.by_agent[agent].append(session)

        project = session.get('project', 'unknown')
        self.by_project[project].append(session)

    def calculate_all(self) -> Dict:
        """Calculate all metrics"""
        return {
            'scope1_total_analytics': self.calculate_total_analytics(),
            'scope2_by_project': self.calculate_by_project_analytics(),
            'scope3_inter_agent': self.calculate_inter_agent_analytics(),
            'scope4_human_performance': self.calculate_human_performance(),
        }

    def calculate_total_analytics(self) -> Dict:
        """Scope 1: Total Analytics"""
        total_sessions = len(self.sessions)
        total_duration = sum(s.get('duration_seconds', 0) for s in self.sessions)

        total_tokens = {
            'input': sum(s.get('tokens', {}).get('input', 0) for s in self.sessions),
            'output': sum(s.get('tokens', {}).get('output', 0) for s in self.sessions),
            'cached': sum(s.get('tokens', {}).get('cached', 0) for s in self.sessions),
            'reasoning': sum(s.get('tokens', {}).get('reasoning', 0) for s in self.sessions),
        }

        total_messages = sum(s.get('message_count', 0) for s in self.sessions)
        total_tool_calls = sum(s.get('tool_call_count', 0) for s in self.sessions)

        # Time range
        timestamps = [s['start_time'] for s in self.sessions if 'start_time' in s]
        time_range = None
        if timestamps:
            time_range = {
                'first': min(timestamps),
                'last': max(timestamps),
                'span_days': (max(timestamps) - min(timestamps)).days if len(timestamps) > 1 else 0,
            }

        return {
            'total_sessions': total_sessions,
            'total_duration_hours': round(total_duration / 3600, 2),
            'total_tokens': total_tokens,
            'total_messages': total_messages,
            'total_tool_calls': total_tool_calls,
            'avg_session_duration_minutes': round(total_duration / max(total_sessions, 1) / 60, 2),
            'avg_messages_per_session': round(total_messages / max(total_sessions, 1), 2),
            'time_range': time_range,
        }

    def calculate_by_project_analytics(self) -> Dict:
        """Scope 2: By-Project Analytics"""
        results = {}

        for project, sessions in self.by_project.items():
            if project == 'unknown':
                continue

            agents_used = Counter(s.get('agent', 'unknown') for s in sessions)
            total_duration = sum(s.get('duration_seconds', 0) for s in sessions)
            total_tokens = sum(s.get('tokens', {}).get('input', 0) + s.get('tokens', {}).get('output', 0) for s in sessions)

            results[project] = {
                'session_count': len(sessions),
                'agents_used': dict(agents_used),
                'total_duration_hours': round(total_duration / 3600, 2),
                'total_tokens': total_tokens,
                'avg_session_duration_minutes': round(total_duration / max(len(sessions), 1) / 60, 2),
            }

        # Sort by session count
        results = dict(sorted(results.items(), key=lambda x: x[1]['session_count'], reverse=True))

        return results

    def calculate_inter_agent_analytics(self) -> Dict:
        """Scope 3: Inter-Agent Comparison"""
        results = {}

        for agent, sessions in self.by_agent.items():
            if agent == 'unknown' or not sessions:
                continue

            total_duration = sum(s.get('duration_seconds', 0) for s in sessions)
            total_tokens_in = sum(s.get('tokens', {}).get('input', 0) for s in sessions)
            total_tokens_out = sum(s.get('tokens', {}).get('output', 0) for s in sessions)
            total_messages = sum(s.get('message_count', 0) for s in sessions)
            total_tool_calls = sum(s.get('tool_call_count', 0) for s in sessions)

            # Calculate response times (assistant message time - user message time)
            response_times = []
            for s in sessions:
                if 'avg_response_time_seconds' in s:
                    response_times.append(s['avg_response_time_seconds'])

            results[agent] = {
                'session_count': len(sessions),
                'avg_session_duration_minutes': round(total_duration / max(len(sessions), 1) / 60, 2),
                'avg_messages_per_session': round(total_messages / max(len(sessions), 1), 2),
                'avg_tool_calls_per_session': round(total_tool_calls / max(len(sessions), 1), 2),
                'token_efficiency': {
                    'avg_input_per_session': round(total_tokens_in / max(len(sessions), 1), 0),
                    'avg_output_per_session': round(total_tokens_out / max(len(sessions), 1), 0),
                    'output_to_input_ratio': round(total_tokens_out / max(total_tokens_in, 1), 3),
                },
                'avg_response_time_seconds': round(sum(response_times) / max(len(response_times), 1), 2) if response_times else None,
            }

        return results

    def calculate_human_performance(self) -> Dict:
        """Scope 4: Human Developer Performance"""

        # Calculate prompt quality indicators
        user_message_lengths = []
        thinking_times = []
        sessions_by_hour = defaultdict(int)
        sessions_by_day = defaultdict(int)

        for s in self.sessions:
            # User message lengths
            if 'avg_user_message_length' in s:
                user_message_lengths.append(s['avg_user_message_length'])

            # Thinking time (gap between assistant → next user)
            if 'avg_thinking_time_seconds' in s:
                thinking_times.append(s['avg_thinking_time_seconds'])

            # Time-of-day patterns
            if 'start_time' in s:
                hour = s['start_time'].hour
                sessions_by_hour[hour] += 1

                day_name = s['start_time'].strftime('%A')
                sessions_by_day[day_name] += 1

        # Session completion indicators
        completed = sum(1 for s in self.sessions if s.get('has_end_time', False))
        abandoned = sum(1 for s in self.sessions if not s.get('has_end_time', False))

        # Peak productivity hours
        peak_hours = sorted(sessions_by_hour.items(), key=lambda x: x[1], reverse=True)[:3]
        peak_days = sorted(sessions_by_day.items(), key=lambda x: x[1], reverse=True)[:3]

        return {
            'total_sessions': len(self.sessions),
            'completed_sessions': completed,
            'abandoned_sessions': abandoned,
            'completion_rate': round(completed / max(len(self.sessions), 1) * 100, 1),
            'avg_user_prompt_length': round(sum(user_message_lengths) / max(len(user_message_lengths), 1), 0) if user_message_lengths else None,
            'avg_thinking_time_seconds': round(sum(thinking_times) / max(len(thinking_times), 1), 2) if thinking_times else None,
            'peak_productivity_hours': [f"{h:02d}:00 ({count} sessions)" for h, count in peak_hours],
            'peak_productivity_days': [f"{day} ({count} sessions)" for day, count in peak_days],
            'sessions_by_hour': dict(sessions_by_hour),
        }


def parse_codex_session(session_file: Path) -> Optional[Dict]:
    """Parse a Codex JSONL session into normalized format"""
    session_data = {
        'agent': 'codex',
        'file': str(session_file),
        'start_time': None,
        'end_time': None,
        'duration_seconds': 0,
        'tokens': {'input': 0, 'output': 0, 'cached': 0, 'reasoning': 0},
        'message_count': 0,
        'tool_call_count': 0,
        'project': None,
    }

    try:
        with open(session_file, 'r') as f:
            events = []
            for line in f:
                if not line.strip():
                    continue
                try:
                    events.append(json.loads(line))
                except:
                    continue

            if not events:
                return None

            # Extract metadata
            for event in events:
                # Timestamps
                ts_str = event.get('timestamp')
                if ts_str:
                    try:
                        ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                        if not session_data['start_time'] or ts < session_data['start_time']:
                            session_data['start_time'] = ts
                        if not session_data['end_time'] or ts > session_data['end_time']:
                            session_data['end_time'] = ts
                    except:
                        pass

                # Tokens
                if event.get('type') == 'event_msg' and event.get('payload', {}).get('type') == 'token_count':
                    info = event.get('payload', {}).get('info', {})
                    if 'last_token_usage' in info:
                        usage = info['last_token_usage']
                        session_data['tokens']['input'] += usage.get('input_tokens', 0)
                        session_data['tokens']['output'] += usage.get('output_tokens', 0)
                        session_data['tokens']['cached'] += usage.get('cached_input_tokens', 0)
                        session_data['tokens']['reasoning'] += usage.get('reasoning_output_tokens', 0)

                # Project (cwd)
                if not session_data['project']:
                    cwd = event.get('payload', {}).get('cwd')
                    if cwd:
                        session_data['project'] = Path(cwd).name

                # Message counting
                if event.get('type') in ['response_item']:
                    payload_type = event.get('payload', {}).get('type')
                    if payload_type == 'message':
                        session_data['message_count'] += 1
                    elif payload_type == 'function_call':
                        session_data['tool_call_count'] += 1

            # Calculate duration
            if session_data['start_time'] and session_data['end_time']:
                session_data['duration_seconds'] = (session_data['end_time'] - session_data['start_time']).total_seconds()
                session_data['has_end_time'] = True
            else:
                session_data['has_end_time'] = False

            return session_data

    except Exception as e:
        print(f"Error parsing {session_file}: {e}")
        return None


def collect_sample_sessions(limit_per_agent: int = 20) -> List[Dict]:
    """Collect sample sessions from all agents"""
    sessions = []

    # Codex sessions
    codex_home = os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex'))
    codex_root = Path(codex_home) / 'sessions'

    if codex_root.exists():
        codex_files = list(codex_root.rglob('rollout-*.jsonl'))
        codex_files = sorted(codex_files, key=lambda p: p.stat().st_mtime, reverse=True)[:limit_per_agent]

        print(f"Parsing {len(codex_files)} Codex sessions...")
        for f in codex_files:
            session = parse_codex_session(f)
            if session:
                sessions.append(session)

    print(f"Collected {len(sessions)} sessions total")
    return sessions


def main():
    """Main metrics prototype"""
    print("Prototype Metrics Calculator")
    print("=" * 60)

    # Collect sample sessions
    sessions = collect_sample_sessions(limit_per_agent=20)

    if not sessions:
        print("No sessions found to analyze")
        return 1

    # Calculate metrics
    metrics = SessionMetrics()
    for session in sessions:
        metrics.add_session(session)

    results = metrics.calculate_all()

    # Write results
    output_file = Path(__file__).parent.parent.parent / 'docs' / 'analytics' / 'prototype-metrics.json'
    output_file.parent.mkdir(parents=True, exist_ok=True)

    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2, default=str)

    print(f"\nMetrics written to: {output_file}")
    print(f"\n{'=' * 60}")
    print("Sample Metrics Preview:")
    print(f"\nScope 1 - Total Analytics:")
    print(f"  Sessions: {results['scope1_total_analytics']['total_sessions']}")
    print(f"  Duration: {results['scope1_total_analytics']['total_duration_hours']} hours")
    print(f"  Messages: {results['scope1_total_analytics']['total_messages']}")
    print(f"  Tokens: {results['scope1_total_analytics']['total_tokens']}")

    print(f"\nScope 2 - By-Project Analytics:")
    for project, data in list(results['scope2_by_project'].items())[:3]:
        print(f"  {project}: {data['session_count']} sessions, {data['total_duration_hours']}h")

    print(f"\nScope 3 - Inter-Agent Comparison:")
    for agent, data in results['scope3_inter_agent'].items():
        print(f"  {agent}: {data['session_count']} sessions, avg {data['avg_messages_per_session']} msgs/session")

    print(f"\nScope 4 - Human Performance:")
    print(f"  Completion rate: {results['scope4_human_performance']['completion_rate']}%")
    if results['scope4_human_performance']['peak_productivity_hours']:
        print(f"  Peak hours: {', '.join(results['scope4_human_performance']['peak_productivity_hours'][:3])}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
