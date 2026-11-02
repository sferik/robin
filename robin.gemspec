# frozen_string_literal: true

require_relative "lib/robin/version"

Gem::Specification.new do |spec|
  spec.name = "robin"
  spec.version = Robin::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "Fast, reliable, fully open-source background jobs for Ruby"
  spec.description = "Robin is a Redis-backed background job system for Ruby with batches, " \
    "reliable fetch, rate limiting, cron, unique jobs, encryption, multi-process " \
    "swarms, a modern web dashboard and a Rails integration that turns itself on in " \
    "Rails apps — all open source under the LGPL."
  spec.homepage = "https://github.com/sferik/robin"
  spec.license = "LGPL-3.0-only"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  files = Dir["lib/**/*", "sig/**/*.{rbs,yaml}", "exe/*", "assets/*.svg", "LICENSE", "COPYING", "README.md", "CHANGELOG.md"]
    .select { |f| File.file?(f) }.reject { |f| f.end_with?(".bundle", ".so", ".dll", ".jar") }
  # Two gems: the default one builds the C extension on install; the
  # java-platform one (built under JRuby with ROBIN_PLATFORM=java, after
  # `rake java:compile`) ships the compiled Java extension and its source.
  java = ENV["ROBIN_PLATFORM"] == "java"
  if java
    jar = "lib/robin_resp/robin_resp.jar"
    raise "#{jar} is missing: run `rake java:compile` under JRuby first" unless File.file?(File.join(__dir__, jar))

    spec.platform = "java"
  else
    spec.extensions = ["ext/robin_resp/extconf.rb"]
  end
  spec.files = files + (java ? [jar, *Dir["ext/java/**/*.java"]] : Dir["ext/robin_resp/*.{c,h,rb}"])
  spec.bindir = "exe"
  spec.executables = ["robin"]
  spec.require_paths = ["lib"]

  spec.add_dependency "json", ">= 2.6"
  # A bundled gem, no longer a default one, since Ruby 3.5 (JRuby 10.1).
  spec.add_dependency "logger", ">= 1.5"
end
