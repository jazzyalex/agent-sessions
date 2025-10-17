#!/usr/bin/env python3
"""
Add Analytics Swift files to AgentSessions.xcodeproj
"""

import re
import uuid
import sys

def generate_xcode_uuid():
    """Generate a 24-character hex UUID compatible with Xcode"""
    return uuid.uuid4().hex[:24].upper()

def main():
    project_path = "AgentSessions.xcodeproj/project.pbxproj"

    # Define the files to add
    files = [
        ("AnalyticsData.swift", "AgentSessions/Analytics/Models/AnalyticsData.swift"),
        ("AnalyticsDateRange.swift", "AgentSessions/Analytics/Models/AnalyticsDateRange.swift"),
        ("AnalyticsService.swift", "AgentSessions/Analytics/Services/AnalyticsService.swift"),
        ("AnalyticsView.swift", "AgentSessions/Analytics/Views/AnalyticsView.swift"),
        ("AnalyticsWindowController.swift", "AgentSessions/Analytics/Views/AnalyticsWindowController.swift"),
        ("StatsCardsView.swift", "AgentSessions/Analytics/Views/StatsCardsView.swift"),
        ("SessionsChartView.swift", "AgentSessions/Analytics/Views/SessionsChartView.swift"),
        ("AgentBreakdownView.swift", "AgentSessions/Analytics/Views/AgentBreakdownView.swift"),
        ("TimeOfDayHeatmapView.swift", "AgentSessions/Analytics/Views/TimeOfDayHeatmapView.swift"),
        ("AnalyticsColors.swift", "AgentSessions/Analytics/Utilities/AnalyticsColors.swift"),
        ("AnalyticsDesignTokens.swift", "AgentSessions/Analytics/Utilities/AnalyticsDesignTokens.swift"),
    ]

    # Read project file
    with open(project_path, 'r') as f:
        content = f.read()

    # Generate UUIDs for each file (both PBXFileReference and PBXBuildFile)
    file_refs = []
    build_files = []

    for name, path in files:
        file_ref_uuid = generate_xcode_uuid()
        build_file_uuid = generate_xcode_uuid()
        file_refs.append((file_ref_uuid, name, path))
        build_files.append((build_file_uuid, file_ref_uuid, name))

    # Find the PBXBuildFile section
    build_file_section = re.search(r'/\* Begin PBXBuildFile section \*/', content)
    if not build_file_section:
        print("ERROR: Could not find PBXBuildFile section")
        return 1

    # Insert PBXBuildFile entries
    build_file_entries = []
    for build_uuid, ref_uuid, name in build_files:
        entry = f"\t\t{build_uuid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_uuid} /* {name} */; }};\n"
        build_file_entries.append(entry)

    insert_pos = build_file_section.end()
    content = content[:insert_pos] + '\n' + ''.join(build_file_entries) + content[insert_pos:]

    # Find the PBXFileReference section
    file_ref_section = re.search(r'/\* Begin PBXFileReference section \*/', content)
    if not file_ref_section:
        print("ERROR: Could not find PBXFileReference section")
        return 1

    # Insert PBXFileReference entries
    file_ref_entries = []
    for ref_uuid, name, path in file_refs:
        entry = f"\t\t{ref_uuid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
        file_ref_entries.append(entry)

    insert_pos = file_ref_section.end()
    content = content[:insert_pos] + '\n' + ''.join(file_ref_entries) + content[insert_pos:]

    # Find PBXSourcesBuildPhase section and add to Sources
    sources_phase = re.search(r'(/\* Sources \*/.*?isa = PBXSourcesBuildPhase;.*?files = \()(.*?)(\);)', content, re.DOTALL)
    if not sources_phase:
        print("ERROR: Could not find PBXSourcesBuildPhase")
        return 1

    # Add build file references to Sources
    sources_entries = []
    for build_uuid, _, name in build_files:
        entry = f"\t\t\t\t{build_uuid} /* {name} in Sources */,\n"
        sources_entries.append(entry)

    current_files = sources_phase.group(2)
    new_files = current_files + ''.join(sources_entries)
    content = content[:sources_phase.start(2)] + new_files + content[sources_phase.end(2):]

    # Find the main group (AgentSessions group) and add Analytics group
    # First, create the Analytics group and its subgroups
    analytics_group_uuid = generate_xcode_uuid()
    models_group_uuid = generate_xcode_uuid()
    services_group_uuid = generate_xcode_uuid()
    views_group_uuid = generate_xcode_uuid()
    utilities_group_uuid = generate_xcode_uuid()

    # Find PBXGroup section to add group definitions
    group_section = re.search(r'/\* Begin PBXGroup section \*/', content)
    if not group_section:
        print("ERROR: Could not find PBXGroup section")
        return 1

    # Build group definitions
    group_entries = f"""
\t\t{analytics_group_uuid} /* Analytics */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{models_group_uuid} /* Models */,
\t\t\t\t{services_group_uuid} /* Services */,
\t\t\t\t{views_group_uuid} /* Views */,
\t\t\t\t{utilities_group_uuid} /* Utilities */,
\t\t\t);
\t\t\tpath = Analytics;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{models_group_uuid} /* Models */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs[0][0]} /* {file_refs[0][1]} */,
\t\t\t\t{file_refs[1][0]} /* {file_refs[1][1]} */,
\t\t\t);
\t\t\tpath = Models;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{services_group_uuid} /* Services */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs[2][0]} /* {file_refs[2][1]} */,
\t\t\t);
\t\t\tpath = Services;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{views_group_uuid} /* Views */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs[3][0]} /* {file_refs[3][1]} */,
\t\t\t\t{file_refs[4][0]} /* {file_refs[4][1]} */,
\t\t\t\t{file_refs[5][0]} /* {file_refs[5][1]} */,
\t\t\t\t{file_refs[6][0]} /* {file_refs[6][1]} */,
\t\t\t\t{file_refs[7][0]} /* {file_refs[7][1]} */,
\t\t\t\t{file_refs[8][0]} /* {file_refs[8][1]} */,
\t\t\t);
\t\t\tpath = Views;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{utilities_group_uuid} /* Utilities */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs[9][0]} /* {file_refs[9][1]} */,
\t\t\t\t{file_refs[10][0]} /* {file_refs[10][1]} */,
\t\t\t);
\t\t\tpath = Utilities;
\t\t\tsourceTree = "<group>";
\t\t}};
"""

    insert_pos = group_section.end()
    content = content[:insert_pos] + group_entries + content[insert_pos:]

    # Find the main AgentSessions group and add Analytics group reference
    # Look for the group that contains AgentSessionsApp.swift
    agent_sessions_group = re.search(r'(B00000112A0A000100000001 /\* AgentSessionsApp\.swift \*/,)', content)
    if agent_sessions_group:
        # Add Analytics group right after AgentSessionsApp.swift
        insert_line = f"\n\t\t\t\t{analytics_group_uuid} /* Analytics */,"
        insert_pos = agent_sessions_group.end()
        content = content[:insert_pos] + insert_line + content[insert_pos:]
    else:
        print("WARNING: Could not find AgentSessionsApp.swift in group, Analytics may not appear in correct location")

    # Write updated project file
    with open(project_path, 'w') as f:
        f.write(content)

    print("✅ Successfully added Analytics files to Xcode project!")
    print(f"   Added {len(files)} Swift files")
    print("\nNext steps:")
    print("1. Open project: open AgentSessions.xcodeproj")
    print("2. Clean build: ⇧⌘K")
    print("3. Build: ⌘B")

    return 0

if __name__ == "__main__":
    sys.exit(main())
