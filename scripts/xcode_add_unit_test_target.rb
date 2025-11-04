#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

proj_path, target_name, scheme_name = ARGV
abort("usage: PROJ TARGET_NAME SCHEME_NAME") unless proj_path && target_name && scheme_name

project = Xcodeproj::Project.open(proj_path)

# Create unit test target (no host app)
target = project.new_target(:unit_test_bundle, target_name, :macos, '14.0')

# Ensure it appears under the Tests group
tests_group = project.main_group['AgentSessionsTests'] || project.main_group.new_group('AgentSessionsLogicTests')

# Basic build settings
[target.build_configuration_list['Debug'], target.build_configuration_list['Release']].each do |cfg|
  cfg.build_settings['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
  cfg.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  cfg.build_settings['CODE_SIGNING_ALLOWED'] = 'YES'
  cfg.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  cfg.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks', '@loader_path/../Frameworks']
  cfg.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  cfg.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "com.triada.#{target_name}"
  cfg.build_settings['SDKROOT'] = 'macosx'
  cfg.build_settings['SWIFT_VERSION'] = '5.9'
  cfg.build_settings.delete('TEST_HOST')
  cfg.build_settings.delete('BUNDLE_LOADER')
end

# Helper to find or create file reference
find_file = lambda do |path|
  abs = File.expand_path(path)
  ref = project.files.find { |f| f.real_path.to_s == abs }
  unless ref
    parent = project.main_group
    # Create intermediate groups
    comps = path.split('/')
    file_name = comps.pop
    comps.each do |seg|
      g = parent.children.find { |c| c.isa == 'PBXGroup' && [c.name, c.path].compact.include?(seg) }
      parent = g || parent.new_group(seg)
    end
    ref = parent.new_file(path)
  end
  ref
end

# Attach sources: test file + 2 helper sources compiled into test bundle
files_to_add = [
  'AgentSessionsTests/ClaudeProbeProjectTests.swift',
  'AgentSessions/ClaudeStatus/ClaudeProbeConfig.swift',
  'AgentSessions/ClaudeStatus/ClaudeProbeProject.swift'
]

files_to_add.each do |p|
  ref = find_file.call(p)
  target.add_file_references([ref])
end

project.save

# Also add testable to the provided scheme
scheme_path = File.join(File.dirname(proj_path), 'AgentSessions.xcodeproj', 'xcshareddata', 'xcschemes', "#{scheme_name}.xcscheme")
if File.exist?(scheme_path)
  scheme = Xcodeproj::XCScheme.new(scheme_path)
  # Remove existing testable with same name if present
  scheme.test_action.testables.reject! do |t|
    t.buildable_references.any? { |br| br.target_uuid == target.uuid }
  end
  tr = Xcodeproj::XCScheme::TestAction::TestableReference.new(nil)
  br = Xcodeproj::XCScheme::BuildableReference.new(target, project)
  tr.buildable_references << br
  scheme.test_action.testables << tr
  scheme.save!
else
  warn "Scheme not found at #{scheme_path}; please add #{target_name} to your scheme manually."
end

puts "✓ Created unit test target #{target_name} and added sources."
