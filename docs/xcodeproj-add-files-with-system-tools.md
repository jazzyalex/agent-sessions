# Add Files to Xcode Project Using System Tools (plutil + Python)

This note documents a lightweight, scriptable way to register Swift files in `AgentSessions.xcodeproj` using only system tools. It’s an alternative to the standard Ruby `xcodeproj` script at `scripts/xcode_add_file.rb` and is handy when Ruby gems aren’t available.

- Converts `project.pbxproj` to JSON via `plutil`.
- Patches JSON with a short Python snippet to add `PBXFileReference`/`PBXBuildFile` and wire them into the desired `PBXGroup` and the app’s `PBXSourcesBuildPhase`.
- Converts JSON back to OpenStep format and builds to verify.

## Commands (copy/paste)

These defaults add one Swift file to the `AgentSessions` target under the “Recovered References” group. Adjust `FILE` and `GROUP_NAME` as needed.

```bash
# One-time: from repo root
export PBX=AgentSessions.xcodeproj/project.pbxproj
export FILE=AgentSessions/GitInspector/Models/InspectorKeys.swift
export TARGET_NAME=AgentSessions
export GROUP_NAME="Recovered References"   # Change to any existing PBXGroup name or path

# 1) Convert to JSON
plutil -convert json -o project.json "$PBX"

# 2) Patch with Python (reads env vars; safe quoting)
python3 - <<'PY'
import json, os, random

with open("project.json","r") as f:
    pbx = json.load(f)

objs = pbx["objects"]

def newid():
    return "".join(random.choice("0123456789ABCDEF") for _ in range(24))

FILE = os.environ["FILE"]
TARGET_NAME = os.environ["TARGET_NAME"]
GROUP_NAME = os.environ["GROUP_NAME"]

# Locate target and its Sources build phase
target_id = None
for k, o in objs.items():
    if o.get("isa") == "PBXNativeTarget" and o.get("name") == TARGET_NAME:
        target_id = k
        break
if not target_id:
    raise SystemExit(f"Target not found: {TARGET_NAME}")

sources_phase_id = None
for pid in objs.get(target_id, {}).get("buildPhases", []):
    if objs.get(pid, {}).get("isa") == "PBXSourcesBuildPhase":
        sources_phase_id = pid
        break
if not sources_phase_id:
    raise SystemExit("Sources phase not found")

# Resolve a PBXGroup to attach the file under (fallback to main group)
project_id = pbx["rootObject"]
main_group_id = objs[project_id]["mainGroup"]

group_id = None
for k, o in objs.items():
    if o.get("isa") == "PBXGroup" and (o.get("name") == GROUP_NAME or o.get("path") == GROUP_NAME):
        group_id = k
        break
if not group_id:
    group_id = main_group_id  # fallback so it still builds

# Reuse or create PBXFileReference
file_ref_id = None
for k, o in objs.items():
    if o.get("isa") == "PBXFileReference" and o.get("path") == FILE and o.get("sourceTree", "") == "SOURCE_ROOT":
        file_ref_id = k
        break
if not file_ref_id:
    file_ref_id = newid()
    objs[file_ref_id] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "sourcecode.swift",
        "path": FILE,
        "sourceTree": "SOURCE_ROOT",
    }

# Ensure file shows up in the chosen group
children = objs[group_id].setdefault("children", [])
if file_ref_id not in children:
    children.append(file_ref_id)

# Reuse or create PBXBuildFile
build_file_id = None
for k, o in objs.items():
    if o.get("isa") == "PBXBuildFile" and o.get("fileRef") == file_ref_id:
        build_file_id = k
        break
if not build_file_id:
    build_file_id = newid()
    objs[build_file_id] = {"isa": "PBXBuildFile", "fileRef": file_ref_id}

# Add to Sources build phase
files = objs[sources_phase_id].setdefault("files", [])
if build_file_id not in files:
    files.append(build_file_id)

with open("project.patched.json", "w") as f:
    json.dump(pbx, f, indent=2, sort_keys=True)
print("Patched project.json -> project.patched.json")
PY

# 3) Convert back to OpenStep and clean up
plutil -convert openstep -o "$PBX" project.patched.json
rm -f project.json project.patched.json

# 4) Build to verify (macOS)
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS' build
```

## Notes

- Change `FILE` to the path you’re adding; re-run the block to add more files.
- To place under a specific `PBXGroup`, set `GROUP_NAME` to that group’s name or path (as shown in `project.pbxproj`). If missing, the script falls back to the project’s main group so builds still pass.
- This approach modifies `project.pbxproj`; commit before and after if you want an easy rollback:
  - `git add -A && git commit -m "chore(xcodeproj): snapshot before plutil patch"`
  - Roll back: `git checkout -- AgentSessions.xcodeproj/project.pbxproj`
- Standard/primary method remains the Ruby helper (`scripts/xcode_add_file.rb`) which ensures exact PBX wiring with `xcodeproj`. Keep this doc as an additional, gem-free option.

## Troubleshooting

- “Target not found” → confirm `TARGET_NAME` matches the Xcode target exactly.
- “Sources phase not found” → ensure the target is a native app target with a `PBXSourcesBuildPhase`.
- File doesn’t appear in Xcode navigator → verify `GROUP_NAME` and that the chosen group actually exists; otherwise it will be attached under the main group.
- Build succeeds but type is still missing → confirm the Swift file has the correct module membership (this script adds it to the target’s Compile Sources phase, which is sufficient for app code).
