#!/usr/bin/env ruby
require 'xcodeproj'

proj_path, target_name, file_path, group_path = ARGV
abort("usage: PROJ TARGET FILE GROUP") unless proj_path && target_name && file_path && group_path

project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == target_name } or abort "target not found"

group = project.main_group
group_path.split('/').each do |seg|
  g = group.children.find { |c| c.isa == 'PBXGroup' && [c.name, c.path].compact.include?(seg) }
  group = g || group.new_group(seg)
end

file_ref = group.files.find { |f| f.path == file_path } || group.new_file(file_path)
phase = target.source_build_phase
phase.add_file_reference(file_ref, true) unless phase.files_references.include?(file_ref)

project.save
puts "✓ Added #{file_path} to #{target_name}"
