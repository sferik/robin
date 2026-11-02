/*
 * NativeIOTest.java - Robin::Redis::NativeIO.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static robin_resp.Rubies.RUBY;
import static robin_resp.Rubies.check;
import static robin_resp.Rubies.context;
import static robin_resp.Rubies.eval;
import static robin_resp.Rubies.inspect;
import static robin_resp.Rubies.raises;

import java.io.IOException;
import java.nio.channels.Selector;
import org.jruby.RubyFloat;
import org.jruby.RubyString;
import org.jruby.exceptions.RaiseException;
import org.jruby.runtime.builtin.IRubyObject;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class NativeIOTest {
  @BeforeEach
  void connect() {
    eval("$ours, $theirs = UNIXSocket.pair");
  }

  @AfterEach
  void disconnect() {
    eval("[$ours, $theirs].each { |s| s.close unless s.closed? }");
  }

  private static IRubyObject ours() {
    return RUBY.getGlobalVariables().get("$ours");
  }

  private static NativeIO.Reader reader() {
    return NativeIO.reader(context(), ours());
  }

  /** NativeIO.fill on $ours from Java (so Java interrupts reach it), into buf. */
  private static IRubyObject fill(RubyString buf, double timeout) {
    return NativeIO.fill(context(), null, ours(), buf, RubyFloat.newFloat(RUBY, timeout));
  }

  private static double seconds(Runnable block) {
    long start = System.nanoTime();
    block.run();
    return (System.nanoTime() - start) / 1e9;
  }

  @Test
  void appendsWhatArrivedAndReturnsItsSize() {
    check(
        "$theirs.write(\"+OK\\r\\n\"); buf = 'head'.b;"
            + " Robin::Redis::NativeIO.fill($ours, buf, 1) == 5 && buf == \"head+OK\\r\\n\""
            + " && buf.encoding == Encoding::BINARY");
  }

  @Test
  void waitsForTheReply() {
    eval("Thread.new { sleep 0.05; $theirs.write(\":1\\r\\n\") }");
    RubyString buf = RubyString.newEmptyBinaryString(RUBY);
    double took = seconds(() -> assertEquals("4", fill(buf, 2).inspect().toString()));
    assertTrue(took >= 0.04, "took " + took);
    assertEquals(":1\r\n", buf.toString());
  }

  @Test
  void readsLongRepliesAChunkAtATime() {
    check(
        "w = Thread.new { $theirs.write('x' * 40_000) }; buf = ''.b; reads = [];"
            + " reads << Robin::Redis::NativeIO.fill($ours, buf, 1) while buf.bytesize < 40_000;"
            + " w.join; reads.sum == 40_000 && reads.max <= 16_384 && buf == 'x' * 40_000");
  }

  @Test
  void nilAtTheEndOfTheStream() {
    assertEquals("nil", inspect("$theirs.close; Robin::Redis::NativeIO.fill($ours, ''.b, 1)"));
  }

  @Test
  void falseWhenNothingArrivesInTime() {
    double took = seconds(() -> assertEquals("false", fill(empty(), 0.05).inspect().toString()));
    assertTrue(took >= 0.04 && took < 1, "took " + took);
  }

  @Test
  void timeoutsOfZeroOrLessOnlyTakeWhatIsThere() {
    assertEquals("false", fill(empty(), 0).inspect().toString());
    assertEquals("false", fill(empty(), -1).inspect().toString());
    eval("$theirs.write(\"+x\\r\\n\")");
    assertEquals("4", fill(empty(), 0).inspect().toString());
  }

  @Test
  void timeoutsAreWholeMillisecondsRoundedUp() {
    assertEquals(0, NativeIO.timeoutMillis(0));
    assertEquals(0, NativeIO.timeoutMillis(-1));
    assertEquals(0, NativeIO.timeoutMillis(Double.NaN));
    assertEquals(1, NativeIO.timeoutMillis(0.0004));
    assertEquals(1, NativeIO.timeoutMillis(0.001));
    assertEquals(2, NativeIO.timeoutMillis(0.0011));
    assertEquals(1500, NativeIO.timeoutMillis(1.5));
    assertEquals(Integer.MAX_VALUE, NativeIO.timeoutMillis(1e12));
  }

  @Test
  void aShortWaitStillWaits() {
    double took = seconds(() -> assertEquals("false", fill(empty(), 0.0004).inspect().toString()));
    assertTrue(took >= 0.0009, "took " + took);
  }

  @Test
  void readsFilesWithoutWaiting() {
    check(
        "File.open('LICENSE') do |f|"
            + "  buf = ''.b; n = Robin::Redis::NativeIO.fill(f, buf, 1);"
            + "  n == [File.size('LICENSE'), 16_384].min && buf == File.binread('LICENSE', n)"
            + " end");
    check(
        "require 'tempfile'; Tempfile.create do |f|"
            + "  f.write('y' * 40_000); f.flush; io = File.open(f.path); buf = ''.b;"
            + "  [Robin::Redis::NativeIO.fill(io, buf, 1), Robin::Redis::NativeIO.fill(io, buf, 1)]"
            + "    == [16_384, 16_384] && buf == 'y' * 32_768"
            + " end");
    check(
        "require 'tempfile'; Tempfile.create do |f|"
            + "  Robin::Redis::NativeIO.fill(File.open(f.path), ''.b, 1).nil?"
            + " end");
  }

  @Test
  void failedReadsRaise() {
    check(
        "File.open('lib') do |dir|"
            + "  begin; Robin::Redis::NativeIO.fill(dir, ''.b, 1); false;"
            + "  rescue SystemCallError, IOError; true; end"
            + " end");
    raises("IOError", "closed stream", "$ours.close; Robin::Redis::NativeIO.fill($ours, ''.b, 1)");
  }

  @Test
  void argumentsMustBeAStringAndAnIO() {
    raises(
        "TypeError",
        "wrong argument type NilClass (expected String)",
        "Robin::Redis::NativeIO.fill($ours, nil, 1)");
    raises(
        "TypeError",
        "no implicit conversion of Integer into IO",
        "Robin::Redis::NativeIO.fill(42, ''.b, 1)");
  }

  @Test
  void threadRaiseInterruptsTheWait() {
    check(
        "w = Thread.new { Robin::Redis::NativeIO.fill($ours, ''.b, 30) };"
            + " w.report_on_exception = false; sleep 0.1;"
            + " t = Process.clock_gettime(Process::CLOCK_MONOTONIC); w.raise('stop waiting');"
            + " msg = begin; w.value; rescue => e; e.message; end;"
            + " msg == 'stop waiting' && Process.clock_gettime(Process::CLOCK_MONOTONIC) - t < 5");
  }

  @Test
  void otherInterruptionsKeepWaiting() {
    check(
        "w = Thread.new { buf = ''.b; Robin::Redis::NativeIO.fill($ours, buf, 5) && buf };"
            + " sleep 0.1; w.wakeup; sleep 0.1; alive = w.alive?;"
            + " $theirs.write(\"+late\\r\\n\"); alive && w.value == \"+late\\r\\n\"");
  }

  @Test
  void aJavaInterruptAloneKeepsWaitingWithoutSpinning() {
    FakeSelector selector = new FakeSelector();
    reader().selector = selector;
    Thread.currentThread().interrupt();
    double took = seconds(() -> assertEquals("false", fill(empty(), 0.2).inspect().toString()));
    assertFalse(Thread.interrupted(), "the interrupt was consumed");
    assertTrue(took >= 0.15, "took " + took);
    assertTrue(selector.selects >= 1 && selector.selects <= 3, selector.selects + " selects");
  }

  @Test
  void failedSelectsRaise() {
    FakeSelector selector = new FakeSelector();
    selector.failSelect = true;
    reader().selector = selector;
    RaiseException raised = assertThrows(RaiseException.class, () -> fill(empty(), 1));
    assertEquals("IOError", raised.getException().getMetaClass().getRealClass().toString());
  }

  @Test
  void eachIOKeepsOneReaderAndOneSelector() {
    NativeIO.Reader reader = reader();
    assertSame(reader, reader());
    assertNull(reader.selector);
    fill(empty(), 0.01);
    Selector selector = reader.selector;
    assertNotNull(selector);
    assertTrue(reader.selectable.keyFor(selector) != null, "registered");
    fill(empty(), 0.01);
    assertSame(selector, reader.selector);
    reader.close();
    assertFalse(selector.isOpen());
  }

  @Test
  void closingWithoutASelectorOrWhenClosingFails() throws IOException {
    reader().close();
    FakeSelector failing = new FakeSelector();
    failing.failClose = true;
    reader().selector = failing;
    reader().close();
    assertFalse(failing.registered(reader().selectable));
  }

  @Test
  void staleWhileNothingIsWaitingToBeRead() {
    check("!Robin::Redis::NativeIO.stale?($ours)");
    check("$theirs.write(\"+push\\r\\n\"); Robin::Redis::NativeIO.stale?($ours)");
    check("Robin::Redis::NativeIO.stale?($ours)");
    assertEquals("7", fill(empty(), 1).inspect().toString());
    check("$theirs.close; Robin::Redis::NativeIO.stale?($ours)");
  }

  @Test
  void theByteStaleReadComesFirstWhateverItIs() {
    for (String bytes : new String[] {"\\x00", "\\xFF", "A"}) {
      check(
          "$theirs.write(\""
              + bytes
              + "\".b); Robin::Redis::NativeIO.stale?($ours) &&"
              + " Robin::Redis::NativeIO.stale?($ours)");
      RubyString buf = empty();
      assertEquals("1", fill(buf, 1).inspect().toString());
      RUBY.getGlobalVariables().set("$robin_buf", buf);
      check("$robin_buf == \"" + bytes + "\".b");
    }
  }

  @Test
  void aStaleCheckThatReadNothingKeepsNothing() {
    eval("$theirs.write('AB')");
    assertEquals("2", fill(empty(), 1).inspect().toString());
    check("!Robin::Redis::NativeIO.stale?($ours)");
    eval("$theirs.write('C')");
    RubyString buf = empty();
    assertEquals("1", fill(buf, 1).inspect().toString());
    assertEquals("C", buf.toString());
  }

  @Test
  void aKeptByteThenTheEndOfTheStream() {
    check("$theirs.write('x'); $theirs.close; Robin::Redis::NativeIO.stale?($ours)");
    RubyString buf = empty();
    assertEquals("1", fill(buf, 1).inspect().toString());
    assertEquals("x", buf.toString());
    assertEquals("nil", fill(empty(), 1).inspect().toString());
  }

  @Test
  void staleWhenTheSocketFailsOrIsClosed() {
    check(
        "s = Socket.new(:INET, :STREAM); begin; Robin::Redis::NativeIO.stale?(s); ensure; s.close;"
            + " end");
    check("s = UNIXSocket.pair.first; s.close; Robin::Redis::NativeIO.stale?(s)");
    reader();
    check("$ours.close; Robin::Redis::NativeIO.stale?($ours)");
    check(
        "require 'tempfile'; Tempfile.create do |f|  f.write('z' * 20_000); f.flush; io ="
            + " File.open(f.path); buf = ''.b;  Robin::Redis::NativeIO.stale?(io) &&"
            + " Robin::Redis::NativeIO.fill(io, buf, 1) == 16_384 end");
  }

  private static RubyString empty() {
    return RubyString.newEmptyBinaryString(RUBY);
  }
}
