# frozen_string_literal: true

# The tests of the Rails integration (Robin::Rails): the robin gem's test
# helper, with Rails loaded first, as a Rails app does, so robin turns its
# Rails integration on itself. Where other tests loaded robin already (in
# one process, as `rake test:serial` and mutant run them), it's required
# as an app that loaded robin before Rails would.
require "rails"
require_relative "../test_helper"
require "robin/rails"

require "tempfile"

# Runs +code+ in a fresh Ruby with +lib+ on its load path; its output.
# From a file, not -e: on JRuby on Windows, a -e script with quotes in
# it printed nothing (the quoting of its command line, it seems).
def run_ruby(code, lib)
  Tempfile.create(["robin", ".rb"]) do |script|
    script.write(code)
    script.close
    IO.popen([RbConfig.ruby, "-I#{lib}", script.path], err: File::NULL, &:read)
  end
end
