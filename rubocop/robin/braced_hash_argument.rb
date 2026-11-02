# frozen_string_literal: true

module RuboCop
  module Cop
    module Robin
      # Hash arguments with a key that isn't a symbol, or is a quoted
      # label, take braces:
      #
      #   # bad
      #   payload.merge("args" => args)
      #   headers.merge("content-type": type)
      #   Thread.handle_interrupt(Shutdown => :never) { ... }
      #
      #   # good
      #   payload.merge({"args" => args})
      #   headers.merge({"content-type": type})
      #   Thread.handle_interrupt({Shutdown => :never}) { ... }
      #
      # JRuby 10.1 can't compile a method (or block) with such a call
      # without braces ("TemporaryClosureVariable cannot be cast to
      # Hash"), so it runs in JRuby's interpreter for good.
      class BracedHashArgument < Base
        extend AutoCorrector

        MSG = "Put braces around a hash argument with a key that isn't a plain symbol (JRuby can't compile the method otherwise)."
        QUOTES = %w[" '].freeze

        def on_send(node)
          node.arguments.each do |arg|
            next unless arg.hash_type? && !arg.braces? && arg.pairs.any? { |pair| uncompilable?(pair.key) }

            add_offense(arg) do |corrector|
              corrector.insert_before(arg, "{")
              corrector.insert_after(arg, "}")
            end
          end
        end
        alias_method :on_csend, :on_send

        private

        # Plain symbols (a: and :a =>) compile; a quoted label ("a-b":)
        # doesn't.
        def uncompilable?(key) = !key.sym_type? || QUOTES.include?(key.loc.begin&.source)
      end
    end
  end
end
