# frozen_string_literal: true

require_relative "test_helper"

class RESPTest < Minitest::Test
  cover "Robin::Redis::RESP*"

  RESP = Robin::Redis::RESP

  def parse(str, pos = 0) = RESP.parse(str.b, pos)

  def test_encode
    out = RESP.encode(["SET", :key, 42, 1.5, nil, "héllo"])

    assert_equal "*6\r\n$3\r\nSET\r\n$3\r\nkey\r\n$2\r\n42\r\n$3\r\n1.5\r\n$0\r\n\r\n$6\r\nhéllo\r\n".b, out
    assert_equal Encoding::BINARY, out.encoding
  end

  def test_encode_appends_to_the_given_buffer
    out = +"x".b

    assert_same out, RESP.encode(["é", "✓"], out)
    assert_equal "x*2\r\n$2\r\né\r\n$3\r\n✓\r\n".b, out
    assert_equal "*0\r\n", RESP.encode([])
  end

  def test_simple_strings_and_errors
    value, pos = parse("+héllo\r\n")

    assert_equal ["héllo", 9], [value, pos]
    assert_equal Encoding::UTF_8, value.encoding
    error, pos = parse("-ERR bad ✓\r\n")

    assert_instance_of Robin::Redis::CommandError, error
    assert_equal "ERR bad ✓", error.message
    assert_equal Encoding::UTF_8, error.message.encoding
    assert_equal 14, pos
  end

  def test_integers
    assert_equal [-12, 6], parse(":-12\r\n")
    assert_equal [10**20, 24], parse(":#{10**20}\r\n")
    assert_raises(ArgumentError) { parse(":abc\r\n") }
  end

  def test_bulk_strings
    assert_equal ["abc", 9], parse("$3\r\nabc\r\n")
    assert_equal ["", 6], parse("$0\r\n\r\n")
    assert_equal [nil, 5], parse("$-1\r\n")
    assert_equal ["a\r\nb", 10], parse("$4\r\na\r\nb\r\n")
    assert_equal Encoding::UTF_8, parse("$2\r\nhi\r\n").first.encoding
  end

  def test_arrays
    assert_equal [["a", 1, nil, [], ["x"]], 32], parse("*5\r\n+a\r\n:1\r\n$-1\r\n*0\r\n*1\r\n$1\r\nx\r\n")
    assert_equal [nil, 5], parse("*-1\r\n")
    assert_equal [[], 4], parse("*0\r\n")
  end

  def test_parses_at_an_offset
    buf = "+one\r\n:2\r\n*1\r\n+three\r\n"

    assert_equal ["one", 6], parse(buf)
    assert_equal [2, 10], parse(buf, 6)
    assert_equal [["three"], 22], parse(buf, 10)
    assert_nil parse(buf, 22)
  end

  def test_incomplete_input
    ["", "+OK", "+OK\r", ":1", "$3\r\nabc", "$3\r\nabc\r", "$3\r\n", "*2\r\n:1\r\n", "*1\r\n$3\r\nab"].each do |partial|
      assert_nil parse(partial), partial.inspect
    end
  end

  def test_huge_counts_are_just_incomplete
    assert_nil parse("*99999999999999\r\n:1\r\n")
  end

  def test_unknown_types
    error = assert_raises(Robin::Redis::ProtocolError) { parse("?x\r\n") }
    assert_equal "unknown RESP type byte 63", error.message
    assert_raises(Robin::Redis::ProtocolError) { parse("%1\r\n+a\r\n+b\r\n") }
  end
end
