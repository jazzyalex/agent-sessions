#!/usr/bin/env python3
"""Legacy developer installer; normal app users use automatic TUI discovery."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--install', action='store_true', help='Apply the printed installation; default is a dry run.')
args = parser.parse_args()
source = Path(__file__).resolve().parents[2] / 'AgentSessions/Resources/OpenCodePresence'
config_root = Path(os.environ.get('OPENCODE_CONFIG_DIR') or
                   (Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'opencode'))
config = config_root / 'cli.json'
original = config.read_bytes() if config.exists() else b'{}'
settings = json.loads(original)
plugins = settings.get('plugins', [])
if not isinstance(plugins, list):
    raise SystemExit('Refusing to replace a non-list plugins configuration.')
version = hashlib.sha256((source / 'tui.js').read_bytes()).hexdigest()[:16]
base = Path.home() / 'Library/Application Support/AgentSessions/Integrations/opencode-presence'
destination = base / version
entry = {'package': str(destination)}
def ours(item):
    value = item.get('package') if isinstance(item, dict) else item
    return isinstance(value, str) and value.startswith(str(base) + '/')
updated = [item for item in plugins if not ours(item)] + [entry]
settings['plugins'] = updated
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
backup = config.with_name(config.name + '.agent-sessions-backup-' + stamp)
print('OpenCode configuration:', config)
print('Local TUI plugin:', destination)
print('Preserved existing plugin entries:', sum(not ours(item) for item in plugins))
print('Configuration backup:', backup if config.exists() else '(new configuration)')
if not args.install:
    print('Dry run. Apply with: python3 integrations/opencode-presence/install.py --install')
    raise SystemExit(0)
destination.mkdir(parents=True, exist_ok=True, mode=0o700)
for name in ['package.json', 'tui.js']:
    target = destination / name
    content = (source / name).read_bytes()
    if target.exists() and target.read_bytes() != content:
        raise SystemExit('Refusing to overwrite a different immutable plugin artifact: ' + str(target))
    target.write_bytes(content)
    target.chmod(0o600)
if updated != plugins or not config.exists():
    config.parent.mkdir(parents=True, exist_ok=True)
    if config.exists(): shutil.copy2(config, backup)
    temporary = config.with_name(config.name + '.agent-sessions.tmp')
    temporary.write_text(json.dumps(settings, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(config)
print('Installed. OpenCode 2.x normally reloads this local plugin live.')
