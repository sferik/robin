# frozen_string_literal: true

# The type check of lib/ against sig/ (`rake steep`): every file, at
# D::Ruby.strict's level but for the diagnostics below, which only say
# Steep can't follow the code, not that a type is wrong:
#
# - UnannotatedEmptyCollection: an unannotated [] or {} is an Array or
#   Hash of untyped: fine for a default (fetch(k, {})), or one merged into
#   a typed Hash. Where a method returns one it fills (each_with_object),
#   its return type is still checked; elsewhere, annotate it (#:).
# - DifferentMethodParameterKind: a method taking `**` (passing its
#   keywords on) where its signature lists them. Callers are still checked
#   against the signature, and arity and argument types still are, too.
# - FallbackAny: an expression Steep can't type (mostly a variable set in
#   a begin and read in its ensure or after it) is untyped. That's no
#   error, and typing them would mean reshaping hot paths (Fetcher#fetch).
#
# Each is a hint, which `steep check` doesn't report (an editor shows it);
# anything at warning or above fails `rake steep`.
D = Steep::Diagnostic

target :lib do
  signature "sig"
  # For this check only, not in the gem: what Robin uses of the gems it
  # integrates with but doesn't depend on (Rack, Rails, Puma, OpenTelemetry,
  # Vernier, TZInfo), and Robin's classes built on Rails' and Puma's (the
  # Railtie, the Active Job adapter, the generators, the Puma plugin),
  # whose signatures would break a check without those gems' signatures.
  signature "steep"

  check "lib"

  library "date", "digest", "erb", "etc", "io-console", "json", "logger", "monitor", "net-http",
    "openssl", "optparse", "securerandom", "socket", "time", "timeout", "uri", "yaml", "zlib"

  configure_code_diagnostics(D::Ruby.strict) do |hash|
    hash[D::Ruby::UnannotatedEmptyCollection] = :hint
    hash[D::Ruby::DifferentMethodParameterKind] = :hint
    hash[D::Ruby::FallbackAny] = :hint
  end
end
