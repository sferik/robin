/*
 * NativeRESPTest.java - Robin::Redis::NativeRESP.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static robin_resp.Rubies.RUBY;
import static robin_resp.Rubies.check;
import static robin_resp.Rubies.context;
import static robin_resp.Rubies.eval;
import static robin_resp.Rubies.inspect;
import static robin_resp.Rubies.raises;

import java.nio.charset.StandardCharsets;
import org.jruby.RubyFixnum;
import org.jruby.RubyString;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.ByteList;
import org.junit.jupiter.api.Test;

class NativeRESPTest {
  /** NativeRESP.parse of a Ruby string literal, inspected. */
  private static String parse(String literal) {
    return inspect("Robin::Redis::NativeRESP.parse(" + literal + ".b, 0)");
  }

  /** NativeRESP.parse of the bytes [begin, begin + size) of a larger array, inspected. */
  private static String parseSlice(String text, int begin, int size) {
    byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
    RubyString buf = RubyString.newString(RUBY, new ByteList(bytes, begin, size, false));
    IRubyObject zero = RubyFixnum.zero(RUBY);
    return NativeRESP.parse(context(), null, buf, zero).inspect().toString();
  }

  @Test
  void loadingDefinesTheModulesAndTheSlotsClass() {
    assertTrue(new RobinRespService().basicLoad(RUBY));
    check(
        "Robin::Redis::NativeRESP.respond_to?(:parse) &&"
            + " Robin::Redis::NativeRESP.respond_to?(:encode)");
    check(
        "Robin::Redis::NativeIO.respond_to?(:fill) && Robin::Redis::NativeIO.respond_to?(:stale?)");
    check("Robin::Redis::NativeSlots.instance_method(:take).arity == 1");
  }

  @Test
  void simpleStringsAndErrors() {
    assertEquals("[\"OK\", 5]", parse("\"+OK\\r\\n\""));
    assertEquals("[\"\", 3]", parse("\"+\\r\\n\""));
    assertEquals("[\"a\\rb\", 6]", parse("\"+a\\rb\\r\\n\""));
    assertEquals("[\"a\\nb\", 6]", parse("\"+a\\nb\\r\\n\""));
    check("Robin::Redis::NativeRESP.parse(\"+é\\r\\n\".b, 0)[0] == \"é\"");
    check("Robin::Redis::NativeRESP.parse(\"+é\\r\\n\".b, 0)[0].encoding == Encoding::UTF_8");
    check(
        "e, n = Robin::Redis::NativeRESP.parse(\"-ERR bad\\r\\n\".b, 0);"
            + " e.instance_of?(Robin::Redis::CommandError) && e.message == 'ERR bad' && n == 10"
            + " && e.message.encoding == Encoding::UTF_8");
  }

  @Test
  void integers() {
    assertEquals("[42, 5]", parse("\":42\\r\\n\""));
    assertEquals("[-7, 5]", parse("\":-7\\r\\n\""));
    assertEquals("[0, 4]", parse("\":0\\r\\n\""));
    assertEquals("[0, 5]", parse("\":-0\\r\\n\""));
    assertEquals("[9223372036854775807, 22]", parse("\":9223372036854775807\\r\\n\""));
    assertEquals("[-9223372036854775808, 23]", parse("\":-9223372036854775808\\r\\n\""));
    assertEquals("[9223372036854775808, 22]", parse("\":9223372036854775808\\r\\n\""));
    assertEquals("[-9223372036854775809, 23]", parse("\":-9223372036854775809\\r\\n\""));
    assertEquals("[1234567890123456789012345, 28]", parse("\":1234567890123456789012345\\r\\n\""));
    check("Robin::Redis::NativeRESP.parse(\":9223372036854775808\\r\\n\".b, 0)[0] == 2**63");
  }

  @Test
  void invalidIntegers() {
    for (String line :
        new String[] {":", ":-", ":1a", ":/", "::", ":--1", ":+1", ":1-", "$x", "*-"}) {
      raises(
          "Robin::Redis::ProtocolError",
          "invalid integer in RESP reply",
          "Robin::Redis::NativeRESP.parse(\"" + line + "\\r\\n\".b, 0)");
    }
  }

  @Test
  void unknownTypeBytes() {
    raises(
        "Robin::Redis::ProtocolError",
        "unknown RESP type byte",
        "Robin::Redis::NativeRESP.parse(\"?x\\r\\n\".b, 0)");
    raises(
        "Robin::Redis::ProtocolError",
        "unknown RESP type byte",
        "Robin::Redis::NativeRESP.parse(\"\\r\\n\".b, 0)");
  }

  @Test
  void bulkStrings() {
    assertEquals("[\"foo\", 9]", parse("\"$3\\r\\nfoo\\r\\n\""));
    assertEquals("[\"\", 6]", parse("\"$0\\r\\n\\r\\n\""));
    assertEquals("[\"a\\r\\nb\", 10]", parse("\"$4\\r\\na\\r\\nb\\r\\n\""));
    assertEquals("[nil, 5]", parse("\"$-1\\r\\n\""));
    assertEquals("[nil, 5]", parse("\"$-5\\r\\n\""));
    assertEquals("[\"\", 7]", parse("\"$-0\\r\\n\\r\\n\""));
    assertEquals("[nil, 24]", parse("\"$-99999999999999999999\\r\\n\""));
    check(
        "Robin::Redis::NativeRESP.parse(\"$2\\r\\né\\r\\n\".b, 0)[0].encoding == Encoding::UTF_8");
  }

  @Test
  void arrays() {
    assertEquals("[[1, \"a\"], 15]", parse("\"*2\\r\\n:1\\r\\n$1\\r\\na\\r\\n\""));
    assertEquals("[[], 4]", parse("\"*0\\r\\n\""));
    assertEquals("[nil, 5]", parse("\"*-1\\r\\n\""));
    assertEquals("[nil, 5]", parse("\"*-9\\r\\n\""));
    assertEquals("[nil, 24]", parse("\"*-99999999999999999999\\r\\n\""));
    assertEquals(
        "[[[1], [nil, \"x\"]], 25]",
        parse("\"*2\\r\\n*1\\r\\n:1\\r\\n*2\\r\\n$-1\\r\\n+x\\r\\n\""));
    // Exactly three bytes per element still fits.
    assertEquals("[[\"\", \"\"], 10]", parse("\"*2\\r\\n+\\r\\n+\\r\\n\""));
  }

  @Test
  void errorsInsideArraysAreReturned() {
    check(
        "v, _ = Robin::Redis::NativeRESP.parse(\"*2\\r"
            + "\\n"
            + "-ERR x\\r"
            + "\\n"
            + ":1\\r"
            + "\\n"
            + "\".b, 0); v[0].instance_of?(Robin::Redis::CommandError) && v[0].message == 'ERR x'"
            + " && v[1] == 1");
  }

  @Test
  void incompleteReplies() {
    for (String literal :
        new String[] {
          "\"\"",
          "\"+OK\"",
          "\"+OK\\r\"",
          "\":1\"",
          "\"$3\\r\\nfo\"",
          "\"$3\\r\\nfoo\"",
          "\"$3\\r\\nfoo\\r\"",
          "\"$2\\r\\na\\r\\n\"",
          "\"*2\\r\\n:1\\r\\n\"",
          "\"*3\\r\\n+\\r\\n+\\r\\n\"",
          "\"*1\\r\\n$3\\r\\nfo\"",
          "\"$99999999999999999999\\r\\n\"",
          "\"*99999999999999999999\\r\\n\"",
          "\"*9223372036854775807\\r\\n\"",
          "\"$9223372036854775807\\r\\nx\\r\\n\""
        }) {
      assertEquals("nil", parse(literal), literal);
    }
  }

  @Test
  void anArrayTooLongForWhatArrivedIsIncompleteBeforeItsElementsAreRead() {
    // Its one element is malformed, but two (or five) can't fit in what's there.
    assertEquals("nil", parse("\"*5\\r\\n?\\r\\n\""));
    assertEquals("nil", parse("\"*2\\r\\n?\\r\\n\""));
  }

  @Test
  void offsets() {
    assertEquals("[\"OK\", 7]", inspect("Robin::Redis::NativeRESP.parse(\"xx+OK\\r\\n\".b, 2)"));
    assertEquals("nil", inspect("Robin::Redis::NativeRESP.parse(\"+OK\\r\\n\".b, 5)"));
    assertEquals("nil", inspect("Robin::Redis::NativeRESP.parse(\"+OK\\r\\n\".b, 4)"));
    assertEquals("nil", inspect("Robin::Redis::NativeRESP.parse(\"+OK\\r\\n\".b, 2**40)"));
    raises(
        "ArgumentError", "negative offset", "Robin::Redis::NativeRESP.parse(\"+OK\\r\\n\".b, -1)");
    raises(
        "TypeError",
        "wrong argument type NilClass (expected String)",
        "Robin::Redis::NativeRESP.parse(nil, 0)");
  }

  @Test
  void stringsSharingABiggerBuffer() {
    // The buffer's bytes start partway into the array and stop short of
    // its end; nothing outside them counts.
    assertEquals("[\"OK\", 5]", parseSlice("zz+OK\r\nyy", 2, 5));
    assertEquals("nil", parseSlice("zz+OK\r\nyy", 2, 4));
    assertEquals("[[\"ab\", 7], 16]", parseSlice("zz*2\r\n$2\r\nab\r\n:7\r\nyy", 2, 16));
    assertEquals("[-12, 6]", parseSlice("zz:-12\r\n", 2, 6));
    assertEquals("[nil, 5]", parseSlice("zz$-1\r\n", 2, 5));
  }

  @Test
  void nestingDepth() {
    String deepest = "\"*1\\r\\n\" * 512 + \":1\\r\\n\"";
    check("Robin::Redis::NativeRESP.parse((" + deepest + ").b, 0)[1] == 512 * 4 + 4");
    raises(
        "Robin::Redis::ProtocolError",
        "RESP reply nested too deeply",
        "Robin::Redis::NativeRESP.parse((\"*1\\r\\n\" * 513 + \":1\\r\\n\").b, 0)");
    // Depth is how deep, not how many arrays.
    check(
        "Robin::Redis::NativeRESP.parse((\"*600\\r\\n\" + \"*1\\r\\n:1\\r\\n\" * 600).b, 0)[0].size"
            + " == 600");
    check(
        "r = \"*2\\r\\n*300\\r\\n\" + \"*0\\r\\n\" * 300 + \"*1\\r\\n\" * 300 + \":1\\r\\n\";"
            + " Robin::Redis::NativeRESP.parse(r.b, 0)[1] == r.bytesize");
  }

  @Test
  void matchesThePureRubyParser() {
    check(
        "['+a\\r\\n', '-E x\\r\\n', ':-12\\r\\n', '$-1\\r\\n', '*-1\\r\\n', '$1\\r\\n\\r\\r\\n',"
            + " '*3\\r\\n:1\\r\\n*1\\r\\n+x\\r\\n$0\\r\\n\\r\\n', ':123456789012345678901\\r\\n',"
            + " '+OK', '$5\\r\\nab'].all? do |s|"
            + "   a = Robin::Redis::NativeRESP.parse(s.b, 0); b = Robin::Redis::RESP.parse(s.b, 0);"
            + "   a.inspect == b.inspect"
            + " end");
  }

  @Test
  void encodesCommands() {
    assertEquals(
        "\"*3\\r\\n$3\\r\\nSET\\r\\n$1\\r\\nk\\r\\n$2\\r\\n12\\r\\n\"",
        inspect("Robin::Redis::NativeRESP.encode(['SET', 'k', 12])"));
    assertEquals("\"*0\\r\\n\"", inspect("Robin::Redis::NativeRESP.encode([])"));
    check("Robin::Redis::NativeRESP.encode([]).encoding == Encoding::BINARY");
    check(
        "args = ['é', -3, 2**70, 1.5, :sym, nil, true];"
            + " Robin::Redis::NativeRESP.encode(args) == Robin::Redis::RESP.encode(args)");
    check(
        "out = 'head'.b; res = Robin::Redis::NativeRESP.encode(['PING'], out);"
            + " res.equal?(out) && out == \"head*1\\r\\n$4\\r\\nPING\\r\\n\"");
    raises(
        "TypeError",
        "wrong argument type String (expected Array)",
        "Robin::Redis::NativeRESP.encode('PING')");
    raises(
        "TypeError",
        "wrong argument type NilClass (expected String)",
        "Robin::Redis::NativeRESP.encode(['PING'], nil)");
  }

  @Test
  void encodesStringsAndIntegersWithoutCallingToS() {
    eval(
        "$to_s_calls = 0\n"
            + "[String, Integer].each do |c|\n"
            + "  c.class_eval do\n"
            + "    alias_method :__counted_to_s, :to_s\n"
            + "    def to_s(*a) = ($to_s_calls += 1; __counted_to_s(*a))\n"
            + "  end\n"
            + "end");
    try {
      assertEquals(
          "\"*2\\r\\n$1\\r\\na\\r\\n$1\\r\\n7\\r\\n\"",
          inspect("Robin::Redis::NativeRESP.encode(['a', 7])"));
      assertEquals("0", inspect("$to_s_calls"));
    } finally {
      eval(
          "[String, Integer].each do |c|\n"
              + "  c.class_eval do\n"
              + "    alias_method :to_s, :__counted_to_s\n"
              + "    remove_method :__counted_to_s\n"
              + "  end\n"
              + "end");
    }
  }
}
