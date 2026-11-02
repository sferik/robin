/*
 * Blocking.java - waiting the way JRuby's own blocking calls do.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import org.jruby.RubyThread;
import org.jruby.runtime.ThreadContext;

/** Runs blocking tasks so Thread#raise and Thread#kill can interrupt them. */
final class Blocking {
  private Blocking() {}

  /**
   * The task's result. JRuby calls the task's wakeup for Thread#raise or Thread#kill, then raises
   * the Ruby exception once the task returns. When a Java interrupt cuts the task short with no
   * Ruby exception behind it (Thread#wakeup), the result is ifInterrupted.
   */
  static <D, R> R run(ThreadContext context, D data, RubyThread.Task<D, R> task, R ifInterrupted) {
    try {
      return context.getThread().executeTask(context, data, task);
    } catch (InterruptedException e) {
      return ifInterrupted;
    }
  }
}
