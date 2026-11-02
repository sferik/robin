# frozen_string_literal: true

require "rake/testtask"

if RUBY_ENGINE == "ruby"
  begin
    require "rake/extensiontask"
    Rake::ExtensionTask.new("robin_resp") do |ext|
      ext.ext_dir = "ext/robin_resp"
      ext.lib_dir = "lib/robin_resp"
    end
  rescue LoadError
    desc "Compile the native RESP parser (rake-compiler not installed; using extconf/make)"
    task :compile do
      Dir.chdir("ext/robin_resp") do
        ruby "extconf.rb"
        sh "make"
      end
      mkdir_p "lib/robin_resp"
      cp Dir["ext/robin_resp/robin_resp.{bundle,so,dll}"], "lib/robin_resp/"
    end
  end
elsif RUBY_ENGINE == "jruby"
  desc "Compile the Java extension (lib/robin_resp/robin_resp.jar)"
  task compile: "java:compile"
else
  desc "Compile the native RESP parser (skipped: #{RUBY_ENGINE} can't load C extensions)"
  task :compile do
    puts "Skipping the native RESP parser on #{RUBY_ENGINE}; Robin uses its pure-Ruby parser."
  end
end

desc "Run the tests: a process per file, several at a time (TEST_JOBS, default: one per CPU)"
task :test do
  require_relative "test/parallel_runner"
  coverage = ENV["COVERAGE"] != "false" && RUBY_ENGINE == "ruby"
  if coverage
    require "simplecov"
    require_relative "test/simplecov_profile"
    rm_rf RobinCoverage::PARTS
  end
  passed = ParallelRunner.run(FileList["test/*_test.rb", "test/rails/*_test.rb"].to_a)
  abort "Tests failed" unless passed
  next unless coverage

  # One report (and threshold check) over every process's results.
  SimpleCov.collate(Dir["#{RobinCoverage::PARTS}/*/.resultset.json"], "robin") do
    minimum_coverage RobinCoverage::THRESHOLDS if RobinCoverage.strict?
  end
end

# `rake duel`: fail if this tree is slower than its baseline at any
# benchmark (DUEL_BASE, DUEL_FILTER and DUEL_FORCE pass through).
require "duel/rake_task"
Duel::RakeTask.new

desc "The same as rake duel"
task perf: :duel

desc "Mutation-test every subject with mutant (slow: CI shards it)"
task :mutant do
  sh "bundle exec mutant run"
end

namespace :mutant do
  desc "List the subjects touched since REF (every one, without a REF), one per line"
  task :subjects, [:ref] do |_task, args|
    require_relative "tasks/mutant_shard"
    puts MutantShard.subjects(args[:ref])
  end

  desc "Mutation-test shard INDEX of TOTAL of the subjects touched since REF (every one, without a REF)"
  task :shard, [:ref, :index, :total] do |_task, args|
    require "shellwords"
    require_relative "tasks/mutant_shard"
    index = Integer(args.fetch(:index))
    total = Integer(args.fetch(:total))
    subjects = MutantShard.subjects(args[:ref])
    mine = MutantShard.shard(subjects, index, total)

    if mine.empty?
      puts "Shard #{index} of #{total}: no subjects"
    else
      puts "Shard #{index} of #{total}: #{mine.size} of #{subjects.size} subjects"
      sh "bundle exec mutant run #{mine.map { |subject| Shellwords.escape(subject) }.join(" ")}"
    end
  end
end

# The type check. sig/ ships in the gem, so it must be valid RBS on its
# own, with just the standard libraries its manifest names (an app's check
# has no signatures for the gems Robin only integrates with). With steep/
# (for the check only: those gems' signatures, and Robin's classes built
# on Rails' and Puma's) and the Steepfile's libraries, lib/ must pass
# Steep's strict check (see the Steepfile) with no errors or warnings.
# Steep runs on CRuby only.
desc "Validate the RBS signatures and type check lib/ against them (Steep)"
task :steep do
  abort "Steep runs on CRuby, not #{RUBY_ENGINE}" unless RUBY_ENGINE == "ruby"

  require "steep"
  require "yaml"
  rbs = ->(libraries, *dirs) { sh "bundle", "exec", "rbs", *libraries.flat_map { |name| ["-r", name] }, *dirs.flat_map { |dir| ["-I", dir] }, "validate" }
  rbs.call(YAML.load_file("sig/manifest.yaml").fetch("dependencies").map { |dependency| dependency.fetch("name") }, "sig")
  project = Steep::Project.new(steepfile_path: Pathname("Steepfile").expand_path)
  Steep::Project::DSL.parse(project, File.read("Steepfile"), filename: "Steepfile")
  rbs.call(project.targets.flat_map { |target| target.options.libraries }.uniq, "sig", "steep")
  sh "bundle exec steep check"
end

namespace :test do
  Rake::TestTask.new(:serial) do |t|
    t.description = "Run the tests in one process"
    t.libs << "test" << "lib"
    t.test_files = FileList["test/*_test.rb", "test/rails/*_test.rb"]
    t.warning = false
  end

  # The CI "rails" job runs these under each gemfiles/rails_*/Gemfile.
  Rake::TestTask.new(:rails) do |t|
    t.description = "Run the Rails integration's tests"
    t.libs << "test" << "lib"
    t.test_files = FileList["test/rails/*_test.rb"]
    t.warning = false
  end
end

# C extension quality: formatting, static analysis, strict warnings and
# 100% line/branch/function coverage. Tool names can be overridden with
# CLANG_FORMAT, CLANG_TIDY, CC and GCOVR (e.g. GCOVR="gcovr --gcov-executable 'llvm-cov gcov'").
namespace :c do
  c_source = "ext/robin_resp/robin_resp.c"
  # extconf.rb defines HAVE_POLL_H where poll(2) exists; check that code too.
  ruby_includes = lambda do
    %w[rubyhdrdir rubyarchhdrdir].map { |key| "-isystem #{RbConfig::CONFIG.fetch(key)}" }.join(" ") + " -DHAVE_POLL_H"
  end

  desc "Check C formatting with clang-format"
  task :format do
    sh "#{ENV.fetch("CLANG_FORMAT", "clang-format")} --dry-run --Werror #{c_source}"
  end

  desc "Run clang-tidy on the C extension"
  task :tidy do
    sysroot = RUBY_PLATFORM.include?("darwin") ? "-isysroot #{`xcrun --show-sdk-path`.strip}" : ""
    sh "#{ENV.fetch("CLANG_TIDY", "clang-tidy")} --quiet #{c_source} -- -std=c99 #{sysroot} #{ruby_includes.call}"
  end

  desc "Compile the C extension with strict warnings as errors"
  task :warnings do
    flags = "-std=c99 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wstrict-prototypes -Werror"
    sh "#{ENV.fetch("CC", "cc")} -fsyntax-only #{flags} #{ruby_includes.call} #{c_source}"
  end

  desc "Lint the C extension (format, tidy, warnings)"
  task lint: %i[format tidy warnings]

  desc "Measure C extension coverage and require 100% lines, branches and functions"
  task :coverage do
    build = File.expand_path("tmp/c-coverage")
    extconf = File.expand_path("ext/robin_resp/extconf.rb")
    rm_rf build
    mkdir_p "#{build}/obj"
    mkdir_p "#{build}/lib/robin_resp"
    Dir.chdir("#{build}/obj") do
      sh({"ROBIN_EXT_COVERAGE" => "1"}, "#{RbConfig.ruby} #{extconf}")
      sh ENV["CC"] ? "make CC=#{ENV["CC"]}" : "make"
      cp Dir["robin_resp.{bundle,so}"], "#{build}/lib/robin_resp/"
    end
    tests = %w[resp_native_test io_native_test gvl_native_test redis_test connection_test resp_test].map { |t| "require './test/#{t}'" }.join("; ")
    # Load the instrumented build first; later requires of the same feature reuse it.
    sh({"COVERAGE" => "false"}, "#{RbConfig.ruby} -I#{build}/lib -rrobin_resp/robin_resp -Itest -Ilib -e \"#{tests}\"")
    sh "#{ENV.fetch("GCOVR", "gcovr")} --root . --object-directory #{build}/obj --filter ext/robin_resp/ " \
      "--txt-metric branch --fail-under-line 100 --fail-under-branch 100 --fail-under-function 100 " \
      "--html-details #{build}/index.html --txt"
  end
end

# The Java extension (JRuby): the counterpart of the C one, plus the
# pool's lock-free bookkeeping. Its quality bar matches the C code's:
# google-java-format, javac -Xlint:all -Werror, and JUnit tests reaching
# 100% line, branch and method coverage (JaCoCo) and killing every
# mutant (PIT). The tools are downloaded into tmp/java-tools and checked
# against these SHA-256 sums. Compiling needs JRuby's jruby.jar: the
# running JRuby's, or set JRUBY_JAR.
namespace :java do
  maven = "https://repo1.maven.org/maven2"
  tools = {
    junit: ["org/junit/platform/junit-platform-console-standalone/6.1.3/junit-platform-console-standalone-6.1.3.jar",
      "e62b96ac475dbcde8599ea905d088f65d90778f86e259b856a49fa5c4ea256ec"],
    jacoco_agent: ["org/jacoco/org.jacoco.agent/0.8.15/org.jacoco.agent-0.8.15-runtime.jar",
      "fb5b0036a0899ea97edfa0fc2c7985b55f3f7c5695028163e5e60d4f3cf6075d"],
    jacoco_cli: ["org/jacoco/org.jacoco.cli/0.8.15/org.jacoco.cli-0.8.15-nodeps.jar",
      "d2b74b20b415163c1f53261e7c5ef4445b788327094208ff821e0c2baf9bc8f1"],
    pitest: ["org/pitest/pitest/1.30.1/pitest-1.30.1.jar",
      "893af485bf0cb7ac2cb9c0a7da20a6213098586e6b768624d90b5b3e0d356616"],
    pitest_entry: ["org/pitest/pitest-entry/1.30.1/pitest-entry-1.30.1.jar",
      "3a05342c7efa4925fa3074337cc4491458a8487715b5401c84838309ea85f48f"],
    pitest_cli: ["org/pitest/pitest-command-line/1.30.1/pitest-command-line-1.30.1.jar",
      "e7fe206c7c6ed8e4529ee9c44e6338df702e67326bf34702d1c57cfca6b31819"],
    pitest_junit5: ["org/pitest/pitest-junit5-plugin/1.2.3/pitest-junit5-plugin-1.2.3.jar",
      "d3e2fcc8db5fd52c0c4ac2fe0d937e64da3df39b657093a1581b5fd463f9be64"],
    google_java_format: ["com/google/googlejavaformat/google-java-format/1.37.0/google-java-format-1.37.0-all-deps.jar",
      "834b2a0c38cb774953322a84b5ca3f2f40dd3156650b3cd44d3b744345962f7a"]
  }
  tool = ->(name) { "tmp/java-tools/#{File.basename(tools.fetch(name).first)}" }
  sources = -> { FileList["ext/java/**/*.java"] }
  test_sources = -> { FileList["test/java/**/*.java"] }
  classes = "tmp/java/classes"
  test_classes = "tmp/java/test-classes"
  jar = "lib/robin_resp/robin_resp.jar"
  jruby_jar = lambda do
    path = ENV["JRUBY_JAR"] || (File.join(RbConfig::CONFIG.fetch("libdir"), "jruby.jar") if RUBY_ENGINE == "jruby")
    abort "Set JRUBY_JAR to JRuby's lib/jruby.jar (or run this under JRuby)" unless path && File.exist?(path)
    path
  end
  test_classpath = -> { [classes, test_classes, jruby_jar.call, tool.call(:junit)].join(File::PATH_SEPARATOR) }
  # google-java-format needs the compiler internals it uses opened up.
  format_jvm_flags = %w[api code file parser tree util].map { |pkg| "--add-exports=jdk.compiler/com.sun.tools.javac.#{pkg}=ALL-UNNAMED" }

  desc "Download the Java tools (JUnit, JaCoCo, PIT, google-java-format) into tmp/java-tools"
  task :tools do
    require "digest"
    require "open-uri"
    mkdir_p "tmp/java-tools"
    tools.each_key do |name|
      path, sha256 = tools.fetch(name)
      file = tool.call(name)
      URI.parse("#{maven}/#{path}").open { |remote| File.binwrite(file, remote.read) } unless File.exist?(file)
      actual = Digest::SHA256.file(file).hexdigest
      next if actual == sha256

      rm file
      abort "#{file}: expected SHA-256 #{sha256}, got #{actual}"
    end
  end

  desc "Compile the Java extension into #{jar}, with all warnings as errors"
  task :compile do
    rm_rf classes
    mkdir_p [classes, File.dirname(jar)]
    sh "javac", "--release", "21", "-Xlint:all", "-Werror", "-cp", jruby_jar.call, "-d", classes, *sources.call
    sh "jar", "cf", jar, "-C", classes, "."
  end

  task compile_tests: %i[tools compile] do
    rm_rf test_classes
    mkdir_p test_classes
    sh "javac", "--release", "21", "-Xlint:all", "-Werror", "-cp", test_classpath.call, "-d", test_classes, *test_sources.call
  end

  # The tests run Ruby code in an embedded JRuby, which needs its home
  # (for the standard library).
  jruby_home = -> { "-Djruby.home=#{File.dirname(jruby_jar.call, 2)}" }
  run_tests = lambda do |*jvm_flags|
    sh "java", jruby_home.call, *jvm_flags, "-jar", tool.call(:junit), "execute", "--disable-banner", "--fail-if-no-tests",
      "--class-path", test_classpath.call, "--scan-class-path", test_classes
  end

  desc "Run the Java extension's JUnit tests"
  task test: :compile_tests do
    run_tests.call
  end

  desc "Measure the Java tests' coverage and require 100% lines, branches and methods (JaCoCo)"
  task coverage: :compile_tests do
    report = "tmp/java/coverage"
    rm_rf ["tmp/java/jacoco.exec", report]
    run_tests.call("-javaagent:#{tool.call(:jacoco_agent)}=destfile=tmp/java/jacoco.exec")
    sh "java", "-jar", tool.call(:jacoco_cli), "report", "tmp/java/jacoco.exec", "--classfiles", classes,
      "--sourcefiles", "ext/java", "--html", report, "--csv", "#{report}.csv"
    # JaCoCo's CSV has a header row and no quoted fields.
    header, *rows = File.readlines("#{report}.csv", chomp: true).map { |line| line.split(",") }
    rows = rows.map { |row| header.zip(row).to_h }
    missed = %w[LINE BRANCH METHOD].to_h { |kind| [kind, rows.sum { |r| Integer(r.fetch("#{kind}_MISSED")) }] }
    puts "Missed: #{missed.map { |kind, count| "#{count} #{kind.downcase}(s)" }.join(", ")} (report: #{report}/index.html)"
    abort "Java coverage is below 100%" unless missed.values.all?(&:zero?)
  end

  desc "Mutation-test the Java extension and require every mutant killed (PIT)"
  task mutation: :compile_tests do
    require "etc"
    pit = %i[pitest pitest_entry pitest_cli pitest_junit5].map { |name| tool.call(name) }
    sh "java", "-cp", [*pit, test_classpath.call].join(File::PATH_SEPARATOR),
      "org.pitest.mutationtest.commandline.MutationCoverageReport",
      "--reportDir", "tmp/java/mutation", "--timestampedReports=false", "--outputFormats", "HTML",
      "--sourceDirs", "ext/java", "--targetClasses", "robin_resp.*", "--targetTests", "robin_resp.*",
      "--classPath", [classes, test_classes, jruby_jar.call].join(","),
      "--mutators", "STRONGER", "--threads", Etc.nprocessors.to_s, "--jvmArgs", jruby_home.call,
      # Coverage is java:coverage's job: PIT also counts the never-called
      # private constructors of classes with only static methods.
      "--mutationThreshold", "100"
  end

  desc "Check the Java sources' formatting (google-java-format)"
  task format: :tools do
    sh "java", *format_jvm_flags, "-jar", tool.call(:google_java_format), "--dry-run", "--set-exit-if-changed",
      *sources.call, *test_sources.call
  end

  desc "Reformat the Java sources (google-java-format)"
  task "format:fix": :tools do
    sh "java", *format_jvm_flags, "-jar", tool.call(:google_java_format), "--replace", *sources.call, *test_sources.call
  end

  desc "Lint the Java extension (formatting, and compiling with -Xlint:all -Werror)"
  task lint: %i[format compile_tests]
end

namespace :web do
  desc "Build the web dashboard (TypeScript, bun)"
  task :build do
    Dir.chdir("web") do
      sh "bun install"
      sh "bun run build"
    end
  end
end

desc "Run benchmarks (RESP parser and end-to-end throughput)"
task bench: :compile do
  ruby "-Ilib bench/resp_parse.rb"
  ruby "-Ilib bench/throughput.rb"
end

namespace :bench do
  # Runs a bench/compare script under that directory's own Gemfile.
  compare = lambda do |script|
    require "bundler"
    gemfile = File.expand_path("bench/compare/Gemfile", __dir__)
    Bundler.with_unbundled_env do
      sh({"BUNDLE_GEMFILE" => gemfile}, "bundle install --quiet")
      sh({"BUNDLE_GEMFILE" => gemfile}, "ruby bench/compare/#{script}.rb")
    end
  end

  desc "Compare Robin and Sidekiq on the same workload (see bench/RESULTS.md)"
  task compare: :compile do
    compare.call("run")
  end

  namespace :compare do
    {
      cluster: "cluster capacity: throughput and Redis CPU as server processes are added",
      scheduled: "scheduled and retry jobs coming due at once",
      idle: "Redis load from many idle server processes",
      payloads: "10 KB and 100 KB job arguments",
      crash: "jobs lost or run twice when a server is killed with SIGKILL",
      pickup: "pickup latency on a quiet queue"
    }.each do |name, what|
      desc "Compare Robin and Sidekiq: #{what} (see bench/RESULTS.md)"
      task name => :compile do
        compare.call(name)
      end
    end
  end
end

task default: %i[compile test]
