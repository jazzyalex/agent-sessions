#!/usr/bin/env python3
"""
Analyze session files to understand message count distribution and noise patterns.
This helps verify the Analytics filtering fix is working correctly.
"""

import json
import os
from pathlib import Path
from collections import defaultdict
from datetime import datetime

def analyze_codex_sessions():
    """Analyze Codex CLI sessions from JSONL files."""
    codex_root = Path.home() / '.codex' / 'sessions'
    stats = defaultdict(int)
    examples = {'zero': [], 'low': [], 'normal': []}

    if not codex_root.exists():
        return stats, examples

    for jsonl_file in codex_root.rglob('*.jsonl'):
        message_count = 0
        session_info = {'file': str(jsonl_file.name), 'messages': []}

        try:
            with open(jsonl_file, 'r') as f:
                for line in f:
                    if line.strip():
                        data = json.loads(line)
                        if data.get('type') == 'message':
                            message_count += 1
                            role = data.get('role', 'unknown')
                            content = data.get('content', '')
                            if isinstance(content, list) and content:
                                content = content[0].get('text', '') if isinstance(content[0], dict) else str(content[0])
                            session_info['messages'].append({
                                'role': role,
                                'preview': content[:100] if content else ''
                            })
        except Exception as e:
            print(f"Error reading {jsonl_file}: {e}")
            continue

        # Categorize by message count
        if message_count == 0:
            stats['zero'] += 1
            if len(examples['zero']) < 2:
                session_info['count'] = 0
                examples['zero'].append(session_info)
        elif 1 <= message_count <= 2:
            stats['low'] += 1
            if len(examples['low']) < 2:
                session_info['count'] = message_count
                examples['low'].append(session_info)
        else:
            stats['normal'] += 1
            if len(examples['normal']) < 1:
                session_info['count'] = message_count
                examples['normal'].append(session_info)

        stats['total'] += 1

    return stats, examples

def analyze_claude_sessions():
    """Analyze Claude Code sessions."""
    claude_root = Path.home() / '.claude' / 'sessions'
    stats = defaultdict(int)
    examples = {'zero': [], 'low': [], 'normal': []}

    if not claude_root.exists():
        return stats, examples

    for session_dir in claude_root.iterdir():
        if not session_dir.is_dir():
            continue

        conversation_file = session_dir / 'conversation.json'
        if not conversation_file.exists():
            continue

        try:
            with open(conversation_file, 'r') as f:
                data = json.load(f)
                messages = data.get('messages', [])
                message_count = len(messages)

                session_info = {
                    'file': session_dir.name,
                    'count': message_count,
                    'messages': []
                }

                for msg in messages[:3]:  # Preview first 3 messages
                    content = msg.get('content', '')
                    if isinstance(content, list) and content:
                        content = content[0].get('text', '') if isinstance(content[0], dict) else str(content[0])
                    session_info['messages'].append({
                        'role': msg.get('role', 'unknown'),
                        'preview': content[:100] if content else ''
                    })

                # Categorize
                if message_count == 0:
                    stats['zero'] += 1
                    if len(examples['zero']) < 2:
                        examples['zero'].append(session_info)
                elif 1 <= message_count <= 2:
                    stats['low'] += 1
                    if len(examples['low']) < 2:
                        examples['low'].append(session_info)
                else:
                    stats['normal'] += 1
                    if len(examples['normal']) < 1:
                        examples['normal'].append(session_info)

                stats['total'] += 1

        except Exception as e:
            print(f"Error reading {conversation_file}: {e}")
            continue

    return stats, examples

def analyze_gemini_sessions():
    """Analyze Gemini CLI sessions."""
    gemini_root = Path.home() / '.gemini' / 'tmp'
    stats = defaultdict(int)
    examples = {'zero': [], 'low': [], 'normal': []}

    if not gemini_root.exists():
        return stats, examples

    for session_file in gemini_root.rglob('session-*.json'):
        try:
            with open(session_file, 'r') as f:
                data = json.load(f)
                messages = data.get('messages', [])
                message_count = len(messages)

                session_info = {
                    'file': session_file.name,
                    'count': message_count,
                    'messages': []
                }

                for msg in messages[:3]:  # Preview first 3 messages
                    session_info['messages'].append({
                        'role': msg.get('role', 'unknown'),
                        'preview': msg.get('content', '')[:100]
                    })

                # Categorize
                if message_count == 0:
                    stats['zero'] += 1
                    if len(examples['zero']) < 2:
                        examples['zero'].append(session_info)
                elif 1 <= message_count <= 2:
                    stats['low'] += 1
                    if len(examples['low']) < 2:
                        examples['low'].append(session_info)
                else:
                    stats['normal'] += 1
                    if len(examples['normal']) < 1:
                        examples['normal'].append(session_info)

                stats['total'] += 1

        except Exception as e:
            print(f"Error reading {session_file}: {e}")
            continue

    return stats, examples

def print_report(agent_name, stats, examples):
    """Print analysis report for an agent."""
    print(f"\n{'='*60}")
    print(f"{agent_name} SESSIONS ANALYSIS")
    print(f"{'='*60}")

    if stats['total'] == 0:
        print("No sessions found")
        return

    print(f"Total sessions: {stats['total']}")
    print(f"  - 0 messages:   {stats['zero']:3d} ({100*stats['zero']/stats['total']:.1f}%)")
    print(f"  - 1-2 messages: {stats['low']:3d} ({100*stats['low']/stats['total']:.1f}%)")
    print(f"  - 3+ messages:  {stats['normal']:3d} ({100*stats['normal']/stats['total']:.1f}%)")

    noise_count = stats['zero'] + stats['low']
    noise_pct = 100 * noise_count / stats['total']
    print(f"\nNOISE (≤2 messages): {noise_count} sessions ({noise_pct:.1f}%)")

    # Show examples
    if examples['zero']:
        print(f"\nExample 0-message sessions:")
        for ex in examples['zero']:
            print(f"  - {ex['file']}: {ex['count']} messages")

    if examples['low']:
        print(f"\nExample 1-2 message sessions:")
        for ex in examples['low']:
            print(f"  - {ex['file']}: {ex['count']} messages")
            for msg in ex['messages']:
                preview = msg['preview'][:50] + '...' if len(msg['preview']) > 50 else msg['preview']
                print(f"    [{msg['role']}] {preview}")

def main():
    print("AGENT SESSIONS NOISE ANALYSIS")
    print("=" * 60)
    print("This script analyzes session files to identify 'noise' sessions")
    print("(those with 0-2 messages) that should be filtered from Analytics.")

    # Analyze each agent type
    codex_stats, codex_examples = analyze_codex_sessions()
    print_report("CODEX CLI", codex_stats, codex_examples)

    claude_stats, claude_examples = analyze_claude_sessions()
    print_report("CLAUDE CODE", claude_stats, claude_examples)

    gemini_stats, gemini_examples = analyze_gemini_sessions()
    print_report("GEMINI CLI", gemini_stats, gemini_examples)

    # Combined summary
    print(f"\n{'='*60}")
    print("COMBINED SUMMARY")
    print(f"{'='*60}")

    total_all = codex_stats['total'] + claude_stats['total'] + gemini_stats['total']
    noise_all = (codex_stats['zero'] + codex_stats['low'] +
                 claude_stats['zero'] + claude_stats['low'] +
                 gemini_stats['zero'] + gemini_stats['low'])

    if total_all > 0:
        print(f"Total sessions across all agents: {total_all}")
        print(f"Total noise sessions (≤2 messages): {noise_all} ({100*noise_all/total_all:.1f}%)")
        print(f"\nWith proper filtering (>2 messages), Analytics should show:")
        print(f"  - Codex:  {codex_stats['normal']} sessions")
        print(f"  - Claude: {claude_stats['normal']} sessions")
        print(f"  - Gemini: {gemini_stats['normal']} sessions")

if __name__ == '__main__':
    main()