/*
 * NativeSlots.java - Robin::Redis::Pool's bookkeeping, without a lock.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.jruby.api.Convert.asSymbol;
import static org.jruby.api.Convert.toDouble;
import static org.jruby.api.Convert.toInt;
import static org.jruby.api.Create.newArray;

import java.util.concurrent.ConcurrentLinkedDeque;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import org.jruby.Ruby;
import org.jruby.RubyArray;
import org.jruby.RubyClass;
import org.jruby.RubyObject;
import org.jruby.RubyThread;
import org.jruby.anno.JRubyClass;
import org.jruby.anno.JRubyMethod;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;

/**
 * Robin::Redis::NativeSlots: a drop-in replacement for Robin::Redis::Pool::Slots. A semaphore
 * counts the connections that may still be checked out and a concurrent deque holds the idle ones,
 * so threads checking connections in and out never wait on each other (JRuby threads run in
 * parallel; one lock would serialize them all).
 */
@JRubyClass(name = "Robin::Redis::NativeSlots")
public final class NativeSlots extends RubyObject implements RubyThread.Task<Long, Boolean> {
  private static final long serialVersionUID = 1L;

  /** The longest wait, in nanoseconds (about 146 years). */
  static final long MAX_WAIT = Long.MAX_VALUE / 2;

  private transient Semaphore free;

  /** Idle connections: the least recently used first. */
  private final transient ConcurrentLinkedDeque<Idle> idle = new ConcurrentLinkedDeque<>();

  /** A connection and when (monotonic seconds) it went idle. */
  private record Idle(IRubyObject connection, double since) {}

  NativeSlots(Ruby runtime, RubyClass type) {
    super(runtime, type);
  }

  @JRubyMethod
  public void initialize(ThreadContext context, IRubyObject size) {
    free = new Semaphore(toInt(context, size));
  }

  /**
   * An idle connection, :create (a slot to fill with a new one), or nil after waiting timeout
   * seconds for either. Thread#raise interrupts it.
   */
  @JRubyMethod
  public IRubyObject take(ThreadContext context, IRubyObject timeout) {
    long deadline = System.nanoTime() + waitNanos(toDouble(context, timeout));
    boolean taken = free.tryAcquire();
    while (!taken) {
      long remaining = Math.max(deadline - System.nanoTime(), 0);
      if (remaining == 0) {
        return context.nil;
      }
      taken = Blocking.run(context, remaining, this, false);
    }
    Idle last = idle.pollLast();
    return last == null ? asSymbol(context, "create") : last.connection();
  }

  /** Returns a connection, idle since since (monotonic seconds). */
  @JRubyMethod
  public void put(ThreadContext context, IRubyObject connection, IRubyObject since) {
    idle.offerLast(new Idle(connection, toDouble(context, since)));
    free.release();
  }

  /** Frees a slot taken with :create but never filled. */
  @JRubyMethod
  public void release(ThreadContext context) {
    free.release();
  }

  /** Makes count more connections available. */
  @JRubyMethod
  public void add(ThreadContext context, IRubyObject count) {
    free.release(toInt(context, count));
  }

  /** Removes and returns the connections idle since before cutoff. */
  @JRubyMethod
  public IRubyObject reap(ThreadContext context, IRubyObject cutoff) {
    double before = toDouble(context, cutoff);
    RubyArray<?> reaped = newArray(context);
    for (Idle oldest = idle.pollFirst(); oldest != null; oldest = idle.pollFirst()) {
      if (oldest.since() >= before) {
        idle.offerFirst(oldest);
        break;
      }
      reaped.append(context, oldest.connection());
    }
    return reaped;
  }

  /** Removes and returns every idle connection. */
  @JRubyMethod
  public IRubyObject drain(ThreadContext context) {
    RubyArray<?> drained = newArray(context);
    for (Idle oldest = idle.pollFirst(); oldest != null; oldest = idle.pollFirst()) {
      drained.append(context, oldest.connection());
    }
    return drained;
  }

  /** Seconds to nanoseconds, from 0 up to MAX_WAIT. */
  static long waitNanos(double seconds) {
    return Math.min((long) Math.max(seconds * 1e9, 0), MAX_WAIT);
  }

  @Override
  public Boolean run(ThreadContext context, Long nanos) throws InterruptedException {
    return free.tryAcquire(nanos, TimeUnit.NANOSECONDS);
  }

  @Override
  public void wakeup(RubyThread thread, Long nanos) {
    thread.getNativeThread().interrupt();
  }
}
