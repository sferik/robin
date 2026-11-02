/*
 * NativeRESP.java - the JRuby counterpart of robin_resp.c's parser, plus a
 * command encoder.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.jruby.api.Convert.castAsArray;
import static org.jruby.api.Convert.castAsString;
import static org.jruby.api.Convert.toLong;
import static org.jruby.api.Create.newArray;
import static org.jruby.api.Create.newString;
import static org.jruby.api.Error.argumentError;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import org.jcodings.specific.UTF8Encoding;
import org.jruby.RubyArray;
import org.jruby.RubyBignum;
import org.jruby.RubyClass;
import org.jruby.RubyFixnum;
import org.jruby.RubyString;
import org.jruby.anno.JRubyMethod;
import org.jruby.anno.JRubyModule;
import org.jruby.exceptions.RaiseException;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.ByteList;

/**
 * Robin::Redis::NativeRESP: a drop-in replacement for the pure-Ruby Robin::Redis::RESP (RESP2),
 * with identical results for well-formed replies.
 *
 * <ul>
 *   <li>{@code parse(buf, pos)} returns {@code [value, next_pos]} when buf holds a complete reply
 *       at pos, nil when more bytes are needed;
 *   <li>error replies become Robin::Redis::CommandError instances (returned, not raised);
 *   <li>strings are tagged UTF-8;
 *   <li>an unknown type byte or a malformed integer line raises Robin::Redis::ProtocolError;
 *   <li>{@code encode(args, out = "".b)} appends a command to out. Strings and Integers go out as
 *       their bytes and digits; anything else as its to_s.
 * </ul>
 */
@JRubyModule(name = "Robin::Redis::NativeRESP")
public final class NativeRESP {
  static final int MAX_DEPTH = 512;

  private static final byte[] CRLF = {'\r', '\n'};

  private NativeRESP() {}

  /** Robin::Redis::NativeRESP.parse(buf, pos) -> [value, next_pos] or nil */
  @JRubyMethod(name = "parse", module = true)
  public static IRubyObject parse(
      ThreadContext context, IRubyObject self, IRubyObject buf, IRubyObject pos) {
    long start = toLong(context, pos);
    ByteList bytes = castAsString(context, buf).getByteList();
    if (start < 0) {
      throw argumentError(context, "negative offset");
    }
    Parser parser = new Parser(context, bytes);
    IRubyObject value = parser.parseAt(start);
    if (value == null) {
      return context.nil;
    }
    return newArray(context, value, RubyFixnum.newFixnum(context.runtime, parser.next));
  }

  /** Robin::Redis::NativeRESP.encode(args, out = "".b) -> out */
  @JRubyMethod(name = "encode", module = true)
  public static IRubyObject encode(ThreadContext context, IRubyObject self, IRubyObject args) {
    return encode(context, self, args, RubyString.newEmptyBinaryString(context.runtime));
  }

  @JRubyMethod(name = "encode", module = true)
  public static IRubyObject encode(
      ThreadContext context, IRubyObject self, IRubyObject args, IRubyObject out) {
    RubyArray<?> list = castAsArray(context, args, "Array");
    RubyString target = castAsString(context, out);
    int count = list.size();
    ByteList encoded = new ByteList();
    header(encoded, '*', count);
    for (int i = 0; i < count; i++) {
      ByteList arg = argument(context, list.eltOk(i));
      header(encoded, '$', arg.realSize());
      encoded.append(arg);
      encoded.append(CRLF);
    }
    target.cat(encoded);
    return target;
  }

  /** Appends a type byte, a number and CRLF. */
  private static void header(ByteList out, char type, long number) {
    out.append(type);
    out.append(digits(number));
    out.append(CRLF);
  }

  private static byte[] digits(long value) {
    return Long.toString(value).getBytes(StandardCharsets.US_ASCII);
  }

  /** What arg.to_s would give, without calling Ruby for Strings and Integers. */
  private static ByteList argument(ThreadContext context, IRubyObject arg) {
    if (arg instanceof RubyString string) {
      return string.getByteList();
    }
    if (arg instanceof RubyFixnum fixnum) {
      return new ByteList(digits(fixnum.getValue()), false);
    }
    return castAsString(context, arg.callMethod(context, "to_s")).getByteList();
  }

  /** One parse: the buffer and where the last complete value ended. */
  static final class Parser {
    private final ThreadContext context;
    private final byte[] bytes;
    private final int begin;
    private final long length;
    private int depth;
    long next;

    Parser(ThreadContext context, ByteList buf) {
      this.context = context;
      this.bytes = buf.unsafeBytes();
      this.begin = buf.begin();
      this.length = buf.realSize();
    }

    /** The value at pos (setting next past it), or null if incomplete. */
    IRubyObject parseAt(long pos) {
      long eol = findCrlf(pos);
      if (eol < 0) {
        return null;
      }
      long line = pos + 1;
      long lineLength = eol - line;
      long body = eol + 2;
      switch (bytes[begin + (int) pos]) {
        case '+':
          next = body;
          return utf8(line, lineLength);
        case '-':
          next = body;
          return context
              .runtime
              .getClassFromPath("Robin::Redis::CommandError")
              .callMethod(context, "new", utf8(line, lineLength));
        case ':':
          next = body;
          return integer(line, lineLength);
        case '$':
          return bulk(length(line, lineLength), body);
        case '*':
          return array(length(line, lineLength), body);
        default:
          throw protocolError("unknown RESP type byte");
      }
    }

    private IRubyObject bulk(long size, long body) {
      if (size < 0) {
        next = body;
        return context.nil;
      }
      if (size > length - body - 2) {
        return null;
      }
      next = body + size + 2;
      return utf8(body, size);
    }

    private IRubyObject array(long count, long body) {
      if (count < 0) {
        next = body;
        return context.nil;
      }
      // Each element needs at least 3 bytes; a count larger than what's
      // left can't be complete yet. Avoids huge allocations.
      if (count > (length - body) / 3) {
        return null;
      }
      if (depth == MAX_DEPTH) {
        throw protocolError("RESP reply nested too deeply");
      }
      depth++;
      IRubyObject[] items = new IRubyObject[(int) count];
      long pos = body;
      for (int i = 0; i < count; i++) {
        IRubyObject item = parseAt(pos);
        if (item == null) {
          return null;
        }
        items[i] = item;
        pos = next;
      }
      depth--;
      next = pos;
      return RubyArray.newArrayMayCopy(context.runtime, items);
    }

    /** Index of the first CRLF at or after pos, or -1. */
    private long findCrlf(long pos) {
      for (long i = pos; i < length - 1; i++) {
        if (bytes[begin + (int) i] == '\r' && bytes[begin + (int) i + 1] == '\n') {
          return i;
        }
      }
      return -1;
    }

    /** The Integer for a line of the form -?[0-9]+. */
    private IRubyObject integer(long line, long lineLength) {
      int from = begin + (int) line;
      int to = from + (int) lineLength;
      int first = firstDigit(from, to);
      try {
        long value = digits(first, to);
        return RubyFixnum.newFixnum(context.runtime, first == from ? value : -value);
      } catch (ArithmeticException tooLong) {
        String text = new String(bytes, from, to - from, StandardCharsets.US_ASCII);
        return RubyBignum.bignorm(context.runtime, new BigInteger(text));
      }
    }

    /**
     * A length or count. Long.MAX_VALUE when too large for a long (more than any buffer holds, so
     * never complete); every negative becomes -1.
     */
    private long length(long line, long lineLength) {
      int from = begin + (int) line;
      int to = from + (int) lineLength;
      int first = firstDigit(from, to);
      boolean negative = first != from;
      try {
        long value = digits(first, to);
        return Math.max(negative ? -value : value, -1);
      } catch (ArithmeticException tooLong) {
        return negative ? -1 : Long.MAX_VALUE;
      }
    }

    /** Where the digits of -?[0-9]+ in bytes[from, to) start. (A CRLF always follows.) */
    private int firstDigit(int from, int to) {
      int first = bytes[from] == '-' ? from + 1 : from;
      if (first == to) {
        throw protocolError("invalid integer in RESP reply");
      }
      for (int i = first; i < to; i++) {
        if (bytes[i] < '0' || bytes[i] > '9') {
          throw protocolError("invalid integer in RESP reply");
        }
      }
      return first;
    }

    /** The value of the digits in bytes[from, to); ArithmeticException past Long.MAX_VALUE. */
    private long digits(int from, int to) {
      long value = 0;
      for (int i = from; i < to; i++) {
        value = Math.addExact(Math.multiplyExact(value, 10), bytes[i] - '0');
      }
      return value;
    }

    private RubyString utf8(long from, long size) {
      ByteList copy =
          new ByteList(bytes, begin + (int) from, (int) size, UTF8Encoding.INSTANCE, true);
      return newString(context, copy);
    }

    private RaiseException protocolError(String message) {
      RubyClass error = (RubyClass) context.runtime.getClassFromPath("Robin::Redis::ProtocolError");
      return RaiseException.from(context.runtime, error, message);
    }
  }
}
