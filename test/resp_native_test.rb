# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "robin"
require "minitest/autorun"
require "minitest/strict"

begin
  require "robin_resp/robin_resp"
rescue LoadError
  nil
end

# Checks that the C parser behaves exactly like the pure-Ruby one.
class RESPNativeTest < Minitest::Test
  RESP = Robin::Redis::RESP

  def setup
    skip "native RESP extension not compiled (run `rake compile`)" unless defined?(Robin::Redis::NativeRESP)
    @rng = Random.new(Integer(ENV.fetch("SEED", 1234)))
  end

  # Error replies are distinct objects; compare them by class and message.
  def normalize(value)
    case value
    when Array then value.map { |v| normalize(v) }
    when Robin::Redis::CommandError then [:error, value.message, value.message.encoding]
    when String then [value, value.encoding]
    else value
    end
  end

  def assert_same_parse(buf, pos = 0)
    ruby = RESP.parse(buf, pos)
    native = Robin::Redis::NativeRESP.parse(buf, pos)
    message = "mismatch for #{buf.byteslice(pos, 120).inspect}"
    if ruby.nil?
      assert_nil native, message
    else
      assert_equal normalize(ruby), normalize(native), message
    end
  end

  def random_string(max = 40)
    chars = ["a", "Z", "0", " ", "é", "✓", "\r", "\n", "\x00", "-", ":"]
    Array.new(@rng.rand(0..max)) { chars.sample(random: @rng) }.join
  end

  def random_reply(depth = 0)
    kinds = %i[simple error int bulk nil_bulk]
    kinds += %i[array nil_array] if depth < 4
    case kinds.sample(random: @rng)
    when :simple then "+#{random_string.delete("\r\n")}\r\n"
    when :error then "-ERR #{random_string.delete("\r\n")}\r\n"
    when :int then ":#{@rng.rand(-10**12..10**12)}\r\n"
    when :bulk
      s = random_string((@rng.rand < 0.05) ? 70_000 : 60)
      "$#{s.bytesize}\r\n#{s}\r\n"
    when :nil_bulk then "$-1\r\n"
    when :array
      n = @rng.rand(0..6)
      "*#{n}\r\n" + Array.new(n) { random_reply(depth + 1) }.join
    when :nil_array then "*-1\r\n"
    end
  end

  def test_random_replies_match
    500.times do
      buf = random_reply.b

      assert_same_parse(buf)
    end
  end

  def test_every_split_point_matches
    100.times do
      buf = (random_reply + random_reply).b
      next if buf.bytesize > 4000

      (0..buf.bytesize).each { |i| assert_same_parse(buf.byteslice(0, i)) }
    end
  end

  def test_offsets_and_pipelines
    replies = Array.new(50) { random_reply }
    buf = replies.join.b
    pos = 0
    replies.size.times do
      assert_same_parse(buf, pos)
      pos = RESP.parse(buf, pos)[1]
    end

    assert_equal buf.bytesize, pos
    assert_nil Robin::Redis::NativeRESP.parse(buf, buf.bytesize)
  end

  def test_resp3_types_are_rejected
    %w[~ > % _ # , ( = !].each do |type|
      assert_raises(Robin::Redis::ProtocolError) { Robin::Redis::NativeRESP.parse("#{type}1\r\n".b, 0) }
    end
  end

  def test_unknown_type_raises_protocol_error
    assert_raises(Robin::Redis::ProtocolError) { RESP.parse("?x\r\n".b, 0) }
    assert_raises(Robin::Redis::ProtocolError) { Robin::Redis::NativeRESP.parse("?x\r\n".b, 0) }
  end

  def test_malformed_input_is_safe
    native = Robin::Redis::NativeRESP

    assert_nil native.parse("$99999999999999999999999\r\nabc".b, 0)
    assert_nil native.parse("*99999999999999999\r\n".b, 0)
    assert_nil native.parse("*99999999999999999999\r\n".b, 0)
    assert_nil native.parse("*2147483647\r\n:1\r\n".b, 0)
    assert_raises(Robin::Redis::ProtocolError) { native.parse(("*1\r\n" * 600 + ":1\r\n").b, 0) }
    assert_raises(ArgumentError) { native.parse("+OK\r\n".b, -1) }
    assert_raises(TypeError) { native.parse(nil, 0) }
  end

  def test_integers_must_be_decimal
    native = Robin::Redis::NativeRESP

    [":abc\r\n", ":\r\n", ":-\r\n", ":1x\r\n", "$x\r\n", "*1.5\r\n"].each do |reply|
      assert_raises(Robin::Redis::ProtocolError, reply) { native.parse(reply.b, 0) }
    end
  end

  def test_large_integers_match_ruby
    [":123456789012345678\r\n", ":-123456789012345678\r\n", ":1234567890123456789012\r\n",
      ":-1234567890123456789012\r\n", "$-99999999999999999999\r\n", "*-99999999999999999999\r\n"].each do |reply|
      assert_equal RESP.parse(reply.b, 0), Robin::Redis::NativeRESP.parse(reply.b, 0), reply
    end
  end

  def test_incomplete_edges
    native = Robin::Redis::NativeRESP

    assert_nil native.parse("".b, 0)
    assert_nil native.parse("+OK\r\n".b, 5)
    assert_nil native.parse("+OK\r".b, 0)
    assert_nil native.parse("$3\r\nab".b, 0)
    assert_nil native.parse("*2\r\n:1\r\n:2".b, 0)
    assert_equal ["a\rb", 6], native.parse("+a\rb\r\n".b, 0)
  end

  def test_nesting_limit_is_exact
    native = Robin::Redis::NativeRESP
    deepest = ("*1\r\n" * 512 + ":1\r\n").b

    assert_equal 1, native.parse(deepest, 0).first.flatten.first
    assert_raises(Robin::Redis::ProtocolError) { native.parse(("*1\r\n" + deepest).b, 0) }
  end

  def test_error_replies_are_command_errors
    2.times do
      error, = Robin::Redis::NativeRESP.parse("-ERR bad\r\n".b, 0)

      assert_instance_of Robin::Redis::CommandError, error
      assert_equal "ERR bad", error.message
    end
  end

  def test_strings_are_utf8
    value, = Robin::Redis::NativeRESP.parse("$2\r\nhi\r\n".b, 0)

    assert_equal Encoding::UTF_8, value.encoding
  end

  def test_survives_gc_stress
    buf = ("*200\r\n" + Array.new(200) { |i| "$5\r\nv#{format("%04d", i)}\r\n" }.join).b
    GC.stress = true
    value, = Robin::Redis::NativeRESP.parse(buf, 0)
    GC.stress = false

    assert_equal 200, value.size
    assert_equal "v0199", value.last
  ensure
    GC.stress = false
  end

  def random_argument
    case @rng.rand(6)
    when 0 then random_string
    when 1 then @rng.rand(-10**15..10**15)
    when 2 then @rng.rand(10**20..10**25) * ((@rng.rand < 0.5) ? -1 : 1)
    when 3 then @rng.rand * 1000
    when 4 then random_string.to_sym
    else [nil, true, :sym, 1r / 3].sample(random: @rng)
    end
  end

  def test_encode_matches_ruby
    500.times do
      args = Array.new(@rng.rand(0..8)) { random_argument }

      assert_equal RESP.encode(args), Robin::Redis::NativeRESP.encode(args), "mismatch for #{args.inspect}"
    end
  end

  def test_encode_appends_binary_bytes
    out = +"x".b
    shown = Object.new
    shown.define_singleton_method(:to_s) { "shown" }

    assert_same out, Robin::Redis::NativeRESP.encode(["é", shown, -1], out)
    assert_equal "x*3\r\n$2\r\né\r\n$5\r\nshown\r\n$2\r\n-1\r\n".b, out
    assert_equal Encoding::BINARY, Robin::Redis::NativeRESP.encode([]).encoding
  end

  def test_encode_rejects_what_is_not_a_command
    assert_raises(TypeError) { Robin::Redis::NativeRESP.encode("PING") }
    assert_raises(TypeError) { Robin::Redis::NativeRESP.encode(["PING"], 1) }
    odd = Object.new
    odd.define_singleton_method(:to_s) { 42 }

    assert_raises(TypeError) { Robin::Redis::NativeRESP.encode([odd]) }
  end
end
