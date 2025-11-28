#!/usr/bin/env ruby
require 'xcodeproj'

proj_path, target_name, file_path, group_path = ARGV
abort("usage: PROJ TARGET FILE GROUP") unless proj_path && target_name && file_path && group_path

project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == target_name } or abort "target not found"

# Navigate to or create the group hierarchy
group = project.main_group
group_path.split('/').each do |seg|
  g = group.children.find { |c| c.isa == 'PBXGroup' && [c.name, c.path].compact.include?(seg) }
  group = g || group.new_group(seg)
end

# Extract just the filename from the full path
filename = File.basename(file_path)

# Check if file reference already exists in this group
file_ref = group.files.find { |f| f.path == file_path }

unless file_ref
  # Create new file reference with just the filename
  file_ref = group.new_file(filename)
  # Set the full path relative to project root and SOURCE_ROOT as sourceTree
  file_ref.path = file_path
  file_ref.source_tree = 'SOURCE_ROOT'
end

# Add to build phase if not already present
phase = target.source_build_phase
phase.add_file_reference(file_ref, true) unless phase.files_references.include?(file_ref)

project.save
puts "✓ Added #{file_path} to #{target_name}"
