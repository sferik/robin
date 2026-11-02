# frozen_string_literal: true

# The native parser is optional: Robin falls back to its pure-Ruby parser
# when it isn't available, so never fail a gem install over it. On engines
# that can't load MRI C extensions (JRuby, TruffleRuby) or without a working
# C compiler, write a Makefile that does nothing.
def write_noop_makefile(reason)
  warn "robin: not building the native RESP parser (#{reason}); using pure Ruby"
  File.write("Makefile", "all install clean distclean static:\n\t@:\n.PHONY: all install clean distclean static\n")
end

if RUBY_ENGINE == "ruby"
  require "mkmf"

  if try_compile("int main(void) { return 0; }")
    $CFLAGS << " -O3 -std=c99 -Wall -Wno-declaration-after-statement" # rubocop:disable Style/GlobalVars -- mkmf API
    if ENV["ROBIN_EXT_COVERAGE"]
      # Instrumented build for `rake c:coverage`.
      $CFLAGS << " -O0 -g --coverage" # rubocop:disable Style/GlobalVars -- mkmf API
      $LDFLAGS << " --coverage" # rubocop:disable Style/GlobalVars -- mkmf API
    end
    have_header("poll.h") # for Robin::Redis::NativeIO (not on Windows)
    create_makefile("robin_resp/robin_resp")
  else
    write_noop_makefile("no working C compiler")
  end
else
  write_noop_makefile("#{RUBY_ENGINE} can't load C extensions")
end
