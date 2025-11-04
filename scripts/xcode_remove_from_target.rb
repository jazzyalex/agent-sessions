#!/usr/bin/env ruby
require 'xcodeproj'
proj_path, target_name, file_path = ARGV
abort("usage: PROJ TARGET FILE") unless proj_path && target_name && file_path
project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == target_name } or abort "target not found"
ref = project.files.find { |f| f.path == file_path || f.real_path.to_s.end_with?(file_path) }
abort("file ref not found: #{file_path}") unless ref
phase = target.source_build_phase
bf = phase.files.find { |f| f.file_ref == ref }
abort("build file not in target: #{file_path}") unless bf
phase.remove_file_reference(ref)
project.save
puts "✓ Removed #{file_path} from #{target_name}"
