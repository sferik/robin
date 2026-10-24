/*
 * NativeSlotsTest.java - Robin::Redis::NativeSlots.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static robin_resp.Rubies.RUBY;
import static robin_resp.Rubies.check;
import static robin_resp.Rubies.context;
import static robin_resp.Rubies.eval;
import static robin_resp.Rubies.inspect;

import org.jruby.RubyFloat;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class NativeSlotsTest {
  @BeforeEach
  void slots() {
    eval("$slots = Robin::Redis::NativeSlots.new(2)");
  }

  private static String take(double timeout) {
    NativeSlots slots = (NativeSlots) RUBY.getGlobalVariables().get("$slots");
    return slots.take(context(), RubyFloat.newFloat(RUBY, timeout)).inspect().toString();
  }

  private static double seconds(Runnable block) {
    long start = System.nanoTime();
    block.run();
    return (System.nanoTime() - start) / 1e9;
  }

  @Test
  void createsUntilFullThenWaits() {
    assertEquals(":create", take(1));
    assertEquals(":create", take(1));
    double took = seconds(() -> assertEquals("nil", take(0.05)));
    assertTrue(took >= 0.04 && took < 1, "took " + took);
    assertEquals("nil", take(0));
    assertEquals("nil", take(-1));
    assertEquals("nil", take(Double.NaN));
  }

  @Test
  void handsOutTheMostRecentlyReturnedFirst() {
    check(
        "2.times { $slots.take(1) }; $slots.put(:a, 1.0); $slots.put(:b, 2.0);"
            + " [$slots.take(1), $slots.take(1)] == [:b, :a]");
  }

  @Test
  void returningOrReleasingFreesASlot() {
    eval("2.times { $slots.take(1) }");
    assertEquals("nil", inspect("$slots.release"));
    assertEquals(":create", take(0));
    assertEquals("nil", inspect("$slots.put(:a, 1.0)"));
    assertEquals(":a", take(0));
  }

  @Test
  void aWaitingTakeIsWokenByAReturn() {
    check(
        "2.times { $slots.take(1) }; w = Thread.new { $slots.take(5) }; sleep 0.05;"
            + " t = Process.clock_gettime(Process::CLOCK_MONOTONIC); $slots.put(:a, 1.0);"
            + " w.value == :a && Process.clock_gettime(Process::CLOCK_MONOTONIC) - t < 2");
  }

  @Test
  void threadRaiseInterruptsAWaitingTake() {
    check(
        "2.times { $slots.take(1) }; w = Thread.new { $slots.take(30) };"
            + " w.report_on_exception = false; sleep 0.05; w.raise('stop waiting');"
            + " (begin; w.value; rescue => e; e.message; end) == 'stop waiting'");
    eval("$slots.release");
    assertEquals(":create", take(0), "the interrupted take took no slot");
  }

  @Test
  void aJavaInterruptAloneKeepsWaiting() {
    eval("2.times { $slots.take(1) }");
    Thread.currentThread().interrupt();
    double took = seconds(() -> assertEquals("nil", take(0.1)));
    assertFalse(Thread.interrupted(), "the interrupt was consumed");
    assertTrue(took >= 0.08, "took " + took);
  }

  @Test
  void addFreesThatManyMoreSlots() {
    eval("$slots.take(1)");
    assertEquals("nil", inspect("$slots.add(2)"));
    assertEquals(":create", take(0));
    assertEquals(":create", take(0));
    assertEquals(":create", take(0));
    assertEquals("nil", take(0));
  }

  @Test
  void addWakesEveryWaitingTake() {
    check(
        "2.times { $slots.take(1) }; ws = Array.new(2) { Thread.new { $slots.take(5) } }; sleep"
            + " 0.05; t = Process.clock_gettime(Process::CLOCK_MONOTONIC); $slots.add(2);"
            + " ws.map(&:value) == [:create, :create] &&"
            + " Process.clock_gettime(Process::CLOCK_MONOTONIC) - t < 2");
  }

  @Test
  void reapsTheConnectionsIdleSinceBeforeTheCutoff() {
    eval("$slots = Robin::Redis::NativeSlots.new(3); 3.times { $slots.take(1) }");
    eval("3.times { |i| $slots.put(:\"c#{i}\", i.to_f) }");
    assertEquals("[]", inspect("$slots.reap(0.0)"));
    assertEquals("[:c0]", inspect("$slots.reap(1.0)"));
    assertEquals("[:c1]", inspect("$slots.reap(1.5)"));
    assertEquals("[]", inspect("$slots.reap(1.5)"));
    assertEquals(":c2", take(0));
    assertEquals(":create", take(0));
  }

  @Test
  void reapsEveryConnectionWhenAllAreIdleTooLong() {
    eval("2.times { $slots.take(1) }; $slots.put(:a, 1.0); $slots.put(:b, 2.0)");
    assertEquals("[:a, :b]", inspect("$slots.reap(10.0)"));
    assertEquals("[]", inspect("$slots.drain"));
  }

  @Test
  void threadWakeupKeepsATakeWaiting() {
    check(
        "2.times { $slots.take(1) }; w = Thread.new { $slots.take(5) }; sleep 0.05; w.wakeup;"
            + " sleep 0.05; alive = w.alive?; $slots.put(:a, 1.0); alive && w.value == :a");
  }

  @Test
  void drainRemovesEveryIdleConnectionOldestFirst() {
    eval("2.times { $slots.take(1) }; $slots.put(:a, 1.0); $slots.put(:b, 2.0)");
    assertEquals("[:a, :b]", inspect("$slots.drain"));
    assertEquals("[]", inspect("$slots.drain"));
    assertEquals(":create", take(0));
  }

  @Test
  void waitsAreWholeNanosecondsFromZeroToAboutACentury() {
    assertEquals(0, NativeSlots.waitNanos(-1));
    assertEquals(0, NativeSlots.waitNanos(0));
    assertEquals(0, NativeSlots.waitNanos(Double.NaN));
    assertEquals(1_500_000_000L, NativeSlots.waitNanos(1.5));
    assertEquals(NativeSlots.MAX_WAIT, NativeSlots.waitNanos(1e30));
    assertEquals(Long.MAX_VALUE / 2, NativeSlots.MAX_WAIT);
  }

  @Test
  void aHugeTimeoutWithASlotFreeDoesNotWait() {
    assertEquals(":create", take(1e30));
  }
}
