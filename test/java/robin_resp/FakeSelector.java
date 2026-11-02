/*
 * FakeSelector.java - a selector the tests control.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import java.io.IOException;
import java.nio.channels.SelectableChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.spi.AbstractSelectableChannel;
import java.nio.channels.spi.AbstractSelector;
import java.nio.channels.spi.SelectorProvider;
import java.util.Set;

/**
 * Waits like a real selector (returning at once while the thread has a Java interrupt pending),
 * counts its selects, and fails them or its close on request.
 */
final class FakeSelector extends AbstractSelector {
  int selects;
  boolean failSelect;
  boolean failClose;

  FakeSelector() {
    super(SelectorProvider.provider());
  }

  @Override
  public synchronized int select(long timeout) throws IOException {
    selects++;
    if (failSelect) {
      throw new IOException("select failed");
    }
    if (!Thread.currentThread().isInterrupted()) {
      try {
        wait(timeout);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }
    return 0;
  }

  @Override
  public synchronized Selector wakeup() {
    notifyAll();
    return this;
  }

  @Override
  public int select() {
    throw new UnsupportedOperationException();
  }

  @Override
  public int selectNow() {
    throw new UnsupportedOperationException();
  }

  @Override
  public Set<SelectionKey> keys() {
    return Set.of();
  }

  @Override
  public Set<SelectionKey> selectedKeys() {
    return Set.of();
  }

  @Override
  protected void implCloseSelector() throws IOException {
    if (failClose) {
      throw new IOException("close failed");
    }
  }

  @Override
  protected SelectionKey register(AbstractSelectableChannel channel, int ops, Object attachment) {
    throw new UnsupportedOperationException();
  }

  /** Whether the channel is registered with it (never: it's fake). */
  boolean registered(SelectableChannel channel) {
    return channel.keyFor(this) != null;
  }
}
