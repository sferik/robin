# frozen_string_literal: true

# The dashboard, served by bin/web. Open to anyone who can reach it: keep it
# on localhost.
require_relative "app"
require "robin/web"

run Robin::Web
