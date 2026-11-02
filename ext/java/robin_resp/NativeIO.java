/*
 * NativeIO.java - the JRuby counterpart of robin_resp.c's socket reader.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.jruby.api.Convert.asBoolean;
import static org.jruby.api.Convert.castAsString;
import static org.jruby.api.Convert.toDouble;

import java.io.IOException;
import java.lang.ref.Cleaner;
import java.nio.ByteBuffer;
import java.nio.channels.ReadableByteChannel;
import java.nio.channels.SelectableChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import org.jruby.RubyFixnum;
import org.jruby.RubyIO;
import org.jruby.RubyString;
import org.jruby.RubyThread;
import org.jruby.anno.JRubyMethod;
import org.jruby.anno.JRubyModule;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.runtime.builtin.InternalVariables;
import org.jruby.util.io.ChannelFD;

/**
 * Robin::Redis::NativeIO: reads replies off a socket.
 *
 * <p>Each socket gets a selector of its own, made the first time a read has to wait and kept (with
 * the socket registered on it) until the socket is garbage collected. Waiting is then a single
 * select, with no registering, cancelling or blocking-mode changes per wait, and any number of
 * threads wait in parallel.
 */
@JRubyModule(name = "Robin::Redis::NativeIO")
public final class NativeIO {
  /** Bytes per read: plenty for a typical reply; longer ones take more reads. */
  static final int READ_CHUNK = 16384;

  /** Where a socket's Reader is kept (an internal variable of its IO). */
  static final String READER = "robin_resp_reader";

  /** What Reader#fill returns at the end of the stream. */
  static final int END = -1;

  /** What Reader#fill returns when nothing arrived in time. */
  static final int TIMED_OUT = -2;

  private static final Cleaner CLEANER = Cleaner.create();

  private NativeIO() {}

  /**
   * Robin::Redis::NativeIO.fill(io, buffer, timeout) -> Integer, nil or false
   *
   * <p>Appends what arrives on io within timeout seconds to buffer and returns how many bytes that
   * was; nil when the server closed the connection, false when nothing arrived in time. A failed
   * read raises IOError or SystemCallError. Thread#raise and Thread#kill interrupt the wait; other
   * interruptions don't.
   */
  @JRubyMethod(name = "fill", module = true)
  public static IRubyObject fill(
      ThreadContext context,
      IRubyObject self,
      IRubyObject io,
      IRubyObject buffer,
      IRubyObject timeout) {
    RubyString buf = castAsString(context, buffer);
    long millis = timeoutMillis(toDouble(context, timeout));
    Reader reader = reader(context, io);
    int count;
    try {
      count = reader.fill(context, buf, millis);
    } catch (IOException e) {
      throw context.runtime.newIOErrorFromException(e);
    }
    switch (count) {
      case TIMED_OUT:
        return context.fals;
      case END:
        return context.nil;
      default:
        return RubyFixnum.newFixnum(context.runtime, count);
    }
  }

  /**
   * Robin::Redis::NativeIO.stale?(io) -> true or false
   *
   * <p>Whether a connection between commands can't be used: the server closed it, it failed, or it
   * holds bytes nothing asked for. Doesn't wait, so it's cheap enough to run before every command.
   * A byte it had to read to find out is kept for the next fill.
   */
  @JRubyMethod(name = "stale?", module = true)
  public static IRubyObject stale(ThreadContext context, IRubyObject self, IRubyObject io) {
    boolean stale;
    try {
      stale = reader(context, io).stale();
    } catch (IOException | RuntimeException e) {
      stale = true;
    }
    return asBoolean(context, stale);
  }

  /** Seconds to whole milliseconds, rounded up (so a short wait isn't none), from 0 to 2^31-1. */
  static long timeoutMillis(double seconds) {
    return (long) Math.ceil(Math.min(Math.max(seconds * 1000.0, 0), Integer.MAX_VALUE));
  }

  /** The io's Reader, made on first use. Raises IOError for a closed io. */
  static Reader reader(ThreadContext context, IRubyObject io) {
    RubyIO rubyIO = RubyIO.convertToIO(context, io);
    InternalVariables variables = rubyIO.getInternalVariables();
    if (variables.getInternalVariable(READER) instanceof Reader reader) {
      return reader;
    }
    Reader reader = new Reader(rubyIO.getOpenFileChecked().fd());
    variables.setInternalVariable(READER, reader);
    CLEANER.register(rubyIO, reader::close);
    return reader;
  }

  /** Reads from one channel, waiting with a selector of its own. */
  static final class Reader implements RubyThread.Task<Reader, Void> {
    final ReadableByteChannel channel;
    final SelectableChannel selectable;
    private final byte[] chunk = new byte[READ_CHUNK];
    private final ByteBuffer chunkBuffer = ByteBuffer.wrap(chunk);
    Selector selector;
    private long waitMillis;

    /** A byte stale? had to read, or -1. */
    int pending = -1;

    Reader(ChannelFD fd) {
      channel = fd.chRead;
      selectable = fd.chSelect;
    }

    /** Bytes appended, END at the end of the stream, or TIMED_OUT. */
    int fill(ThreadContext context, RubyString buf, long millis) throws IOException {
      if (pending >= 0) {
        buf.cat((byte) pending);
        pending = -1;
        return 1 + Math.max(read(buf), 0);
      }
      // A file's read never comes back empty, so files never wait.
      long deadline = System.nanoTime() + (millis * 1_000_000);
      int count = read(buf);
      while (count == 0) {
        long remaining = Math.max(Math.ceilDiv(deadline - System.nanoTime(), 1_000_000), 0);
        if (remaining == 0) {
          return TIMED_OUT;
        }
        await(context, remaining);
        count = read(buf);
      }
      return count;
    }

    /** Whether there's anything to read (or the stream ended), without waiting. */
    boolean stale() throws IOException {
      if (pending >= 0 || selectable == null) {
        return true;
      }
      chunkBuffer.clear().limit(1);
      int count = nonBlocking().read(chunkBuffer);
      if (count > 0) {
        pending = chunk[0] & 0xff;
      }
      return count != 0;
    }

    /** Appends what's there now (without waiting) and returns its size, or END. */
    private int read(RubyString buf) throws IOException {
      chunkBuffer.clear();
      int count = nonBlocking().read(chunkBuffer);
      buf.cat(chunk, 0, Math.max(count, 0));
      return count;
    }

    /** The channel, made non-blocking if it can be (a socket's always can). */
    private ReadableByteChannel nonBlocking() throws IOException {
      if (selectable != null) {
        selectable.configureBlocking(false);
      }
      return channel;
    }

    /** Waits up to millis for something to read; Thread#raise and Thread#kill interrupt it. */
    private void await(ThreadContext context, long millis) throws IOException {
      if (selector == null) {
        selector = selectable.provider().openSelector();
        selectable.register(selector, SelectionKey.OP_READ);
      }
      waitMillis = millis;
      Blocking.run(context, this, this, null);
    }

    @Override
    public Void run(ThreadContext context, Reader reader) {
      try {
        selector.select(waitMillis);
      } catch (IOException e) {
        throw context.runtime.newIOErrorFromException(e);
      }
      return null;
    }

    @Override
    public void wakeup(RubyThread thread, Reader reader) {
      selector.wakeup();
    }

    /** Closes the selector, if any (when the socket is garbage collected). */
    void close() {
      try {
        if (selector != null) {
          selector.close();
        }
      } catch (IOException e) {
        // Nothing to do: the selector's file descriptor is gone either way.
      }
    }
  }
}
