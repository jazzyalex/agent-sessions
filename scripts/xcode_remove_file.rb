#!/usr/bin/env ruby
require 'xcodeproj'

proj_path, target_name, file_path = ARGV
abort("usage: PROJ TARGET FILE") unless proj_path && target_name && file_path

project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == target_name } or abort "target not found"

# Find the file reference by path
file_ref = project.files.find { |f| f.path == file_path }

unless file_ref
  puts "⚠ File not found in project: #{file_path}"
  exit 1
end

# Remove from build phase
phase = target.source_build_phase
build_file = phase.files_references.find { |f| f == file_ref }
if build_file
  phase.files.each do |bf|
    if bf.file_ref == file_ref
      bf.remove_from_project
      break
    end
  end
end

# Remove the file reference itself
file_ref.remove_from_project

project.save
puts "✓ Removed #{file_path} from #{target_name}"
