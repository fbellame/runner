#!/usr/bin/env ruby
# Adds a source file to a target's group and Sources build phase, idempotently.
# Usage: ruby scripts/xcadd.rb <relative_file_path> <target_name>
require 'xcodeproj'

path = ARGV[0]
target_name = ARGV[1]
abort "usage: xcadd.rb <file> <target>" unless path && target_name

project = Xcodeproj::Project.open('Runner.xcodeproj')
target = project.targets.find { |t| t.name == target_name }
abort "target #{target_name} not found" unless target

# Already referenced? Bail out cleanly.
if project.files.any? { |f| f.real_path.to_s == File.expand_path(path) }
  puts "already present: #{path}"
  exit 0
end

# Walk/create the group chain matching the on-disk folders (drop leading target dir).
parts = path.split('/')
parts.shift # e.g. "Runner" or "RunnerTests"
filename = parts.pop
group = project.main_group.find_subpath(target_name, true)
parts.each { |p| group = group.find_subpath(p, true) }
group.set_source_tree('SOURCE_ROOT')

file_ref = group.new_reference(path)
target.add_file_references([file_ref])
project.save
puts "added: #{path} -> #{target_name}"
