# frozen_string_literal: true

# Checks Robin's extension API (EXTENDING.md) against what it promised:
# a table from each name to what it is. A class, module or constant must
# still be one. A method must still be public (or, for a method a
# subclass overrides, defined) and still take every call its pinned
# signature took: it may gain optional arguments, never lose any or gain
# required ones.
module ExtensionAPIAssertions
  # A method a subclass calls or overrides: it may be private.
  Hook = Struct.new(:signature)

  def self.hook(signature) = Hook.new(signature)

  def assert_extension_api(table)
    problems = table.filter_map { |name, promise| extension_api_problem(name, promise) }

    assert_empty problems, "Robin's extension API changed (see EXTENDING.md):\n#{problems.join("\n")}"
  end

  def extension_api_problem(name, promise)
    return kind_problem(name, promise) if promise.is_a?(Symbol)

    owner_name, separator, method_name = name.rpartition(/[#.]/)
    owner = Object.const_get(owner_name) if Object.const_defined?(owner_name)
    return "#{name}: #{owner_name} is gone" unless owner

    hook = promise.is_a?(Hook)
    method = api_method(owner, separator, method_name, public_only: !hook)
    return "#{name}: #{hook ? "not defined" : "not public"}" unless method

    pinned = hook ? promise.signature : promise
    current = signature_of(method)
    return if accepts_every_call?(pinned, current)

    "#{name}: took #{pinned.inspect}, now takes #{current.inspect}"
  end

  # Whether a method taking +current+ arguments takes every call one
  # taking +pinned+ arguments did. Both are Method#parameters without
  # names for positional arguments, and without the block (any method
  # takes one).
  def accepts_every_call?(pinned, current)
    was = arguments(pinned)
    now = arguments(current)
    positional_ok = now[:required] <= was[:required] &&
      (now[:rest] || now[:required] + now[:optional] >= was[:required] + was[:optional]) &&
      (now[:rest] || !was[:rest])
    keywords_ok = (now[:keyrest] || (was[:keywords] - now[:keywords]).empty?) &&
      (now[:required_keywords] - was[:required_keywords]).empty? &&
      (now[:keyrest] || !was[:keyrest])
    positional_ok && keywords_ok
  end

  private

  def kind_problem(name, kind)
    return "#{name}: is gone" unless Object.const_defined?(name)

    value = Object.const_get(name)
    now = if value.is_a?(Class) then :class
    elsif value.is_a?(Module) then :module
    else :constant
    end
    "#{name}: was a #{kind}, is now a #{now}" unless now == kind
  end

  def api_method(owner, separator, name, public_only:)
    return owner.instance_method(:initialize) if separator == "." && name == "new"

    target = (separator == ".") ? owner.singleton_class : owner
    defined = public_only ? target.public_method_defined?(name) : target.method_defined?(name) || target.private_method_defined?(name)
    defined ? target.instance_method(name) : nil
  end

  def signature_of(method)
    method.parameters.filter_map do |type, name|
      next if type == :block

      %i[key keyreq].include?(type) ? [type, name] : [type]
    end
  end

  def arguments(signature)
    types = signature.map(&:first)
    {
      required: types.count(:req), optional: types.count(:opt), rest: types.include?(:rest),
      keywords: signature.filter_map { |type, name| name if %i[key keyreq].include?(type) },
      required_keywords: signature.filter_map { |type, name| name if type == :keyreq },
      keyrest: types.include?(:keyrest)
    }
  end
end
