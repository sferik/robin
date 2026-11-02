# frozen_string_literal: true

# The tests of the Rails integration (Robin::Rails): the robin gem's test
# helper, with Rails loaded first, as a Rails app does, so robin turns its
# Rails integration on itself. Where other tests loaded robin already (in
# one process, as `rake test:serial` and mutant run them), it's required
# as an app that loaded robin before Rails would.
require "rails"
require_relative "../test_helper"
require "robin/rails"
