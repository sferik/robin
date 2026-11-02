/*
 * robin_resp.c - native RESP (Redis protocol) reply parser and socket
 * reader for Robin.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 *
 * Defines Robin::Redis::NativeRESP.parse(buf, pos), a drop-in replacement
 * for the pure-Ruby Robin::Redis::RESP.parse (RESP2) with identical results
 * for well-formed replies:
 *
 *   - returns [value, next_pos] when buf holds a complete reply at pos;
 *   - returns nil when more bytes are needed;
 *   - error replies become Robin::Redis::CommandError instances (returned,
 *     not raised);
 *   - strings are tagged UTF-8;
 *   - an unknown type byte or a malformed integer line raises
 *     Robin::Redis::ProtocolError.
 *
 * Also defines Robin::Redis::NativeRESP.encode(args, out = "".b), the
 * counterpart of Robin::Redis::RESP.encode, and, where poll(2) exists,
 * Robin::Redis::NativeIO (below). Robin::NativeGVL (at the end) measures
 * how long threads wait for the GVL, on Rubies with thread event hooks.
 */

#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/thread.h>
#include <string.h>
#ifdef HAVE_POLL_H
#include <ruby/io.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif
#include <stdint.h>
#include <time.h>

#define ROBIN_MAX_DEPTH 512

/* Decimal digits that always fit in a long long. */
#define ROBIN_FAST_DIGITS 18

/* Sentinel meaning "incomplete": never a value the parser produces. */
#define INCOMPLETE Qundef

static VALUE cCommandError = Qnil;
static VALUE cProtocolError = Qnil;
static ID id_new;
static ID id_to_s;

/* Ruby wraps its string constructors in macros that special-case
 * compile-time constants; the parentheses call the functions directly and
 * avoid branches that can never run here. */
static VALUE utf8_string(const char *ptr, long len) {
    return (rb_utf8_str_new)(ptr, len); // NOLINT(readability-redundant-parentheses)
}

static VALUE binary_string(const char *ptr, long len) {
    return (rb_str_new)(ptr, len); // NOLINT(readability-redundant-parentheses)
}

typedef struct {
    const char *ptr;
    long len;
    int depth;
} parser_t;

static VALUE lookup_class(VALUE *cache, const char *path) {
    if (NIL_P(*cache)) {
        *cache = rb_path2class(path);
        rb_gc_register_mark_object(*cache);
    }
    return *cache;
}

NORETURN(static void protocol_error(const char *message));
static void protocol_error(const char *message) {
    rb_raise(lookup_class(&cProtocolError, "Robin::Redis::ProtocolError"), "%s", message);
}

/* Index of the first "\r\n" at or after pos, or -1. */
static long find_crlf(const parser_t *p, long pos) {
    const char *start = p->ptr + pos;
    const char *end = p->ptr + p->len;

    while (start < end) {
        const char *cr = memchr(start, '\r', (size_t)(end - start));
        if (cr == NULL || cr + 1 == end) {
            return -1;
        }
        if (cr[1] == '\n') {
            return (long)(cr - p->ptr);
        }
        start = cr + 1;
    }
    return -1;
}

/* The Integer for a line of the form -?[0-9]+; anything else is a protocol
 * error. Short numbers are converted directly, long ones by Ruby. */
static VALUE line_to_integer(const char *s, long n) {
    long first = (n > 0 && s[0] == '-') ? 1 : 0;
    long long value = 0;

    if (first == n) {
        protocol_error("invalid integer in RESP reply");
    }
    for (long i = first; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') {
            protocol_error("invalid integer in RESP reply");
        }
    }
    if (n - first > ROBIN_FAST_DIGITS) {
        return rb_str_to_inum(binary_string(s, n), 10, Qtrue);
    }
    for (long i = first; i < n; i++) {
        value = (value * 10) + (s[i] - '0');
    }
    return LL2NUM(first ? -value : value);
}

/* A length or count. Too large to fit a long means the reply can't be
 * complete yet (it would need more memory than exists): returns 0. Lengths
 * below zero all mean "null", so huge negatives become -1. */
static int line_to_length(const char *s, long n, long *out) {
    VALUE num = line_to_integer(s, n);

    if (FIXNUM_P(num)) {
        *out = FIX2LONG(num);
        return 1;
    }
    if (rb_big_sign(num)) {
        return 0;
    }
    *out = -1;
    return 1;
}

static VALUE parse_at(parser_t *p, long pos, long *next);

/* Recursion is bounded by ROBIN_MAX_DEPTH. */
static VALUE parse_array(parser_t *p, long pos, long count, long *next) { // NOLINT(misc-no-recursion)
    VALUE items = Qnil;

    /* Each element needs at least 3 bytes (":0\r\n" is 4); a count larger
     * than what's left can't be complete yet. Avoids huge allocations. */
    if (count > (p->len - pos) / 3) {
        return INCOMPLETE;
    }
    if (p->depth == ROBIN_MAX_DEPTH) {
        protocol_error("RESP reply nested too deeply");
    }
    p->depth++;
    items = rb_ary_new_capa(count);
    for (long i = 0; i < count; i++) {
        VALUE item = parse_at(p, pos, &pos);
        if (item == INCOMPLETE) {
            p->depth--;
            return INCOMPLETE;
        }
        rb_ary_push(items, item);
    }
    p->depth--;
    *next = pos;
    return items;
}

static VALUE parse_at(parser_t *p, long pos, long *next) { // NOLINT(misc-no-recursion)
    long eol = find_crlf(p, pos);
    long size = 0;

    if (eol < 0) {
        return INCOMPLETE;
    }

    const char *line = p->ptr + pos + 1;
    long line_len = eol - pos - 1;
    long body = eol + 2;

    switch ((unsigned char)p->ptr[pos]) {
    case '+':
        *next = body;
        return utf8_string(line, line_len);

    case '-':
        *next = body;
        return rb_funcall(lookup_class(&cCommandError, "Robin::Redis::CommandError"), id_new, 1,
                          utf8_string(line, line_len));

    case ':':
        *next = body;
        return line_to_integer(line, line_len);

    case '$':
        if (!line_to_length(line, line_len, &size)) {
            return INCOMPLETE;
        }
        if (size < 0) {
            *next = body;
            return Qnil;
        }
        if (size > p->len - body - 2) {
            return INCOMPLETE;
        }
        *next = body + size + 2;
        return utf8_string(p->ptr + body, size);

    case '*':
        if (!line_to_length(line, line_len, &size)) {
            return INCOMPLETE;
        }
        if (size < 0) {
            *next = body;
            return Qnil;
        }
        return parse_array(p, body, size, next);

    default:
        protocol_error("unknown RESP type byte");
    }
}

/*
 * call-seq:
 *   Robin::Redis::NativeRESP.parse(buf, pos) -> [value, next_pos] or nil
 */
static VALUE native_parse(VALUE self, VALUE buf, VALUE vpos) {
    long pos = NUM2LONG(vpos);
    long next = 0;
    parser_t p;
    VALUE value = Qnil;

    (void)self;
    StringValue(buf);
    if (pos < 0) {
        rb_raise(rb_eArgError, "negative offset");
    }
    p.ptr = RSTRING_PTR(buf);
    p.len = RSTRING_LEN(buf);
    p.depth = 0;

    value = parse_at(&p, pos, &next);
    RB_GC_GUARD(buf); // NOLINT(portability-no-assembler) -- Ruby's GC guard idiom
    if (value == INCOMPLETE) {
        return Qnil;
    }
    return rb_assoc_new(value, LONG2NUM(next));
}

/* Appends a type byte, a length or count, and CRLF. */
static void append_header(VALUE out, char type, long number) {
    char header[32];
    int len = snprintf(header, sizeof(header), "%c%ld\r\n", type, number);

    (rb_str_cat)(out, header, len); // NOLINT(readability-redundant-parentheses)
}

/* Appends one bulk string: arg's bytes when it's a String, its digits when
 * it's a small Integer, else the bytes of its to_s. */
static void append_argument(VALUE out, VALUE arg) {
    char digits[24];

    if (FIXNUM_P(arg)) {
        int len = snprintf(digits, sizeof(digits), "%ld", FIX2LONG(arg));
        append_header(out, '$', len);
        (rb_str_cat)(out, digits, len); // NOLINT(readability-redundant-parentheses)
    } else {
        if (RB_SPECIAL_CONST_P(arg) || RB_BUILTIN_TYPE(arg) != T_STRING) {
            arg = rb_funcall(arg, id_to_s, 0);
            StringValue(arg);
        }
        append_header(out, '$', RSTRING_LEN(arg));
        (rb_str_cat)(out, RSTRING_PTR(arg), RSTRING_LEN(arg)); // NOLINT(readability-redundant-parentheses)
        RB_GC_GUARD(arg); // NOLINT(portability-no-assembler) -- Ruby's GC guard idiom
    }
    (rb_str_cat)(out, "\r\n", 2); // NOLINT(readability-redundant-parentheses)
}

/*
 * call-seq:
 *   Robin::Redis::NativeRESP.encode(args, out = "".b) -> out
 *
 * Appends the command +args+ to +out+, byte for byte what
 * Robin::Redis::RESP.encode appends.
 */
static VALUE native_encode(int argc, VALUE *argv, VALUE self) {
    VALUE args = Qnil;
    VALUE out = Qnil;

    (void)self;
    rb_scan_args(argc, argv, "11", &args, &out);
    Check_Type(args, T_ARRAY);
    if (NIL_P(out)) {
        out = binary_string("", 0);
    }
    StringValue(out);
    append_header(out, '*', RARRAY_LEN(args));
    for (long i = 0; i < RARRAY_LEN(args); i++) {
        append_argument(out, RARRAY_AREF(args, i));
    }
    return out;
}

#ifdef HAVE_POLL_H
/*
 * Robin::Redis::NativeIO: reads replies off a socket. Waiting for a reply
 * and reading it are one release of the GVL (Ruby's IO releases and
 * retakes it around each syscall), which matters with many worker threads.
 */

/* Bytes per read: plenty for a typical reply; longer ones take more reads. */
#define ROBIN_READ_CHUNK 16384

/* read_t.status when nothing arrived in time (errno values are positive). */
#define ROBIN_TIMED_OUT (-1)

typedef struct {
    int fd;
    int timeout_ms;
    ssize_t count;
    int status;
    char data[ROBIN_READ_CHUNK];
} read_t;

/* Runs without the GVL: waits until the socket is readable, then reads. */
static void *read_without_gvl(void *arg) {
    read_t *r = arg;
    struct pollfd pfd = {.fd = r->fd, .events = POLLIN, .revents = 0};
    int ready = poll(&pfd, 1, r->timeout_ms);

    if (ready <= 0) {
        r->status = ready == 0 ? ROBIN_TIMED_OUT : errno;
        return NULL;
    }
    r->count = read(r->fd, r->data, sizeof(r->data));
    r->status = r->count < 0 ? errno : 0;
    return NULL;
}

/* Seconds to whole milliseconds, rounded up (so a short wait isn't none). */
static int to_timeout_ms(VALUE timeout) {
    double ms = NUM2DBL(timeout) * 1000.0;

    if (ms <= 0) {
        return 0;
    }
    if (ms >= (double)INT_MAX) {
        return INT_MAX;
    }
    int whole = (int)ms;
    return whole < ms ? whole + 1 : whole;
}

/*
 * call-seq:
 *   Robin::Redis::NativeIO.fill(io, buffer, timeout) -> Integer, nil or false
 *
 * Appends what arrives on +io+ within +timeout+ seconds to +buffer+ and
 * returns how many bytes that was; nil when the server closed the
 * connection, false when nothing arrived in time. A failed read raises
 * SystemCallError. Thread#raise and Thread#kill interrupt the wait; other
 * interruptions restart it (with the full timeout).
 */
static VALUE native_fill(VALUE self, VALUE io, VALUE buffer, VALUE timeout) {
    read_t r;

    (void)self;
    StringValue(buffer);
    r.fd = rb_io_descriptor(io);
    r.timeout_ms = to_timeout_ms(timeout);
    do {
        r.count = 0;
        r.status = 0;
        /* Raises here if Thread#raise or #kill interrupted the wait. */
        rb_thread_call_without_gvl(read_without_gvl, &r, RUBY_UBF_IO, NULL);
    } while (r.status == EINTR); /* interrupted for nothing (Thread#wakeup, a signal): wait again */
    if (r.status == ROBIN_TIMED_OUT) {
        return Qfalse;
    }
    if (r.status != 0) {
        rb_syserr_fail(r.status, "reading from Redis");
    }
    if (r.count == 0) {
        return Qnil;
    }
    (rb_str_cat)(buffer, r.data, r.count); // NOLINT(readability-redundant-parentheses)
    return LONG2NUM(r.count);
}

/* roundtrip_t.status values besides 0 and errno values (positive). */
#define ROBIN_STALE (-2)
#define ROBIN_WRITE_TIMED_OUT (-3)

/* What a round trip has done so far: interrupted (EINTR), it resumes. */
typedef struct {
    int fd;
    const char *data;
    long length;
    long written;
    int write_timeout_ms;
    read_t read;
    int status;
} roundtrip_t;

/* Whether the connection can't be used: closed, failed, or holding bytes
 * nothing asked for. Peeks without reading or waiting. */
static int is_stale(int fd) {
    char byte = 0;
    ssize_t peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);

    /* EAGAIN (the same value as EWOULDBLOCK here): nothing to read, as it
     * should be. */
    return !(peeked < 0 && errno == EAGAIN);
}

/* Runs without the GVL: checks the connection (before anything is
 * written), writes the commands, then waits for the replies and reads
 * what has arrived. */
static void *roundtrip_without_gvl(void *arg) {
    roundtrip_t *rt = arg;

    if (rt->written == 0 && is_stale(rt->fd)) {
        rt->status = ROBIN_STALE;
        return NULL;
    }
    while (rt->written < rt->length) {
        ssize_t n = write(rt->fd, rt->data + rt->written, (size_t)(rt->length - rt->written));
        if (n >= 0) {
            rt->written += n;
            continue;
        }
        if (errno != EAGAIN) {
            rt->status = errno;
            return NULL;
        }
        struct pollfd pfd = {.fd = rt->fd, .events = POLLOUT, .revents = 0};
        int ready = poll(&pfd, 1, rt->write_timeout_ms);
        if (ready <= 0) {
            rt->status = ready == 0 ? ROBIN_WRITE_TIMED_OUT : errno;
            return NULL;
        }
    }
    read_without_gvl(&rt->read);
    rt->status = rt->read.status;
    return NULL;
}

/* Runs the round trip, resuming it after interruptions for nothing
 * (Thread#wakeup, a signal); raises if Thread#raise or #kill interrupted it. */
static VALUE run_roundtrip(VALUE arg) {
    roundtrip_t *rt =
        (roundtrip_t *)arg; // NOLINT(performance-no-int-to-ptr) -- rb_ensure passes it as a VALUE

    do {
        rt->read.count = 0;
        rt->status = 0;
        rb_thread_call_without_gvl(roundtrip_without_gvl, rt, RUBY_UBF_IO, NULL);
    } while (rt->status == EINTR);
    return Qnil;
}

/* Unlocks what native_roundtrip locked (nil: a frozen string, never locked). */
static VALUE unlock_string(VALUE str) {
    return NIL_P(str) ? Qnil : rb_str_unlocktmp(str);
}

/*
 * call-seq:
 *   Robin::Redis::NativeIO.roundtrip(io, data, buffer, write_timeout, read_timeout)
 *     -> Integer, nil, false, :stale or [written, errno]
 *
 * Sends +data+ (encoded commands) on +io+ and appends the first of the
 * replies to +buffer+, all in one release of the GVL. Returns what
 * NativeIO.fill would for the read; :stale, having sent nothing, when the
 * connection can't be used (see NativeIO.stale?); or, when the write
 * failed, [bytes written, errno], with a nil errno for a write that timed
 * out. A failed read raises SystemCallError. Thread#raise and Thread#kill
 * interrupt it, leaving the connection unusable; other interruptions
 * resume it.
 */
static VALUE native_roundtrip(VALUE self, VALUE io, VALUE data, VALUE buffer, VALUE write_timeout,
                              VALUE read_timeout) {
    roundtrip_t rt;

    (void)self;
    StringValue(data);
    StringValue(buffer);
    rt.fd = rb_io_descriptor(io);
    rt.length = RSTRING_LEN(data);
    rt.written = 0;
    rt.write_timeout_ms = to_timeout_ms(write_timeout);
    rt.read.fd = rt.fd;
    rt.read.timeout_ms = to_timeout_ms(read_timeout);
    /*
     * Nothing may change data while it's being written. A frozen string
     * can't change (and Ruby 4.0 refuses to lock one); others are locked.
     */
    VALUE locked = OBJ_FROZEN(data) ? Qnil : rb_str_locktmp(data);
    rt.data = RSTRING_PTR(data);
    rb_ensure(run_roundtrip, (VALUE)&rt, unlock_string, locked);
    RB_GC_GUARD(data);

    if (rt.status == ROBIN_STALE) {
        return ID2SYM(rb_intern("stale"));
    }
    if (rt.written < rt.length) {
        return rb_assoc_new(LONG2NUM(rt.written),
                            rt.status == ROBIN_WRITE_TIMED_OUT ? Qnil : INT2NUM(rt.status));
    }
    if (rt.status == ROBIN_TIMED_OUT) {
        return Qfalse;
    }
    if (rt.status != 0) {
        rb_syserr_fail(rt.status, "reading from Redis");
    }
    if (rt.read.count == 0) {
        return Qnil;
    }
    (rb_str_cat)(buffer, rt.read.data, rt.read.count); // NOLINT(readability-redundant-parentheses)
    return LONG2NUM(rt.read.count);
}

/*
 * call-seq:
 *   Robin::Redis::NativeIO.stale?(io) -> true or false
 *
 * Whether a connection between commands can't be used: the server closed
 * it, it failed, or it holds bytes nothing asked for. Peeks without
 * reading or waiting, so it's cheap enough to run before every command.
 */
static VALUE native_stale_p(VALUE self, VALUE io) {
    (void)self;
    return is_stale(rb_io_descriptor(io)) ? Qtrue : Qfalse;
}
#endif

/*
 * Robin::NativeGVL: the total time threads have spent waiting for the GVL.
 * Ruby calls gvl_event when a thread starts waiting for the GVL (READY,
 * without the GVL) and when it gets it (RESUMED, with it), possibly from
 * several native threads at once, and not necessarily on the native
 * thread that runs the Ruby thread: a thread woken by another (a new one,
 * or one joining a thread that ends) is READY on the waker's. So the
 * start of a wait is kept with the Ruby thread, in a slot of the
 * thread-specific storage Ruby keeps for tools like this (in a native
 * thread's variable, a woken thread's wait was counted from a READY long
 * before), and each wait is added to one total atomically. The slot holds
 * a pointer, so the start is kept in one only where a pointer has 64 bits
 * (elsewhere a nanosecond timestamp wouldn't fit, and there's no
 * Robin::NativeGVL: Robin::GVL measures nothing, as on JRuby).
 */
#if UINTPTR_MAX >= UINT64_MAX
#define ROBIN_NATIVE_GVL 1
static rb_internal_thread_specific_key_t gvl_ready_key;
static rb_internal_thread_event_hook_t *gvl_hook;
static uint64_t gvl_wait_ns;
static uint64_t gvl_started_at;

static uint64_t monotonic_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return ((uint64_t)now.tv_sec * 1000000000U) + (uint64_t)now.tv_nsec;
}

static void gvl_event(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data) {
    (void)user_data;
    if (event == RUBY_INTERNAL_THREAD_EVENT_READY) {
        void *ready_at = (void *)(uintptr_t)monotonic_ns(); // NOLINT(performance-no-int-to-ptr): a timestamp
        rb_internal_thread_specific_set(data->thread, gvl_ready_key, ready_at);
        return;
    }
    uint64_t ready_at = (uint64_t)(uintptr_t)rb_internal_thread_specific_get(data->thread, gvl_ready_key);
    /*
     * A thread already waiting when measuring started has no start since:
     * its stamp is older (or none, or from before a stop, its wait's end
     * unseen), and its wait isn't counted.
     */
    if (ready_at >= __atomic_load_n(&gvl_started_at, __ATOMIC_RELAXED)) {
        __atomic_fetch_add(&gvl_wait_ns, monotonic_ns() - ready_at, __ATOMIC_RELAXED);
    }
    rb_internal_thread_specific_set(data->thread, gvl_ready_key, NULL);
}

/* Starts measuring (again); a no-op while measuring. */
static VALUE native_gvl_start(VALUE self) {
    (void)self;
    if (gvl_hook == NULL) {
        __atomic_store_n(&gvl_started_at, monotonic_ns(), __ATOMIC_RELAXED);
        gvl_hook = rb_internal_thread_add_event_hook(
            gvl_event, RUBY_INTERNAL_THREAD_EVENT_READY | RUBY_INTERNAL_THREAD_EVENT_RESUMED, NULL);
    }
    return Qnil;
}

/* Stops measuring; the total stays. */
static VALUE native_gvl_stop(VALUE self) {
    (void)self;
    if (gvl_hook != NULL) {
        rb_internal_thread_remove_event_hook(gvl_hook);
        gvl_hook = NULL;
    }
    return Qnil;
}

static VALUE native_gvl_running_p(VALUE self) {
    (void)self;
    return gvl_hook != NULL ? Qtrue : Qfalse;
}

/* Nanoseconds all threads have waited for the GVL while measuring. */
static VALUE native_gvl_wait_ns(VALUE self) {
    (void)self;
    return ULL2NUM(__atomic_load_n(&gvl_wait_ns, __ATOMIC_RELAXED));
}
#endif

/* Called by Ruby's `require`, so it must have external linkage. */
void Init_robin_resp(void) { // NOLINT(misc-use-internal-linkage)
    VALUE robin = rb_define_module("Robin");
    VALUE redis = rb_define_module_under(robin, "Redis");
    VALUE native = rb_define_module_under(redis, "NativeRESP");

    rb_ext_ractor_safe(true);
    id_new = rb_intern("new");
    id_to_s = rb_intern("to_s");
    rb_define_module_function(native, "parse", native_parse, 2);
    rb_define_module_function(native, "encode", native_encode, -1);
#ifdef HAVE_POLL_H
    VALUE native_io = rb_define_module_under(redis, "NativeIO");
    rb_define_module_function(native_io, "fill", native_fill, 3);
    rb_define_module_function(native_io, "stale?", native_stale_p, 1);
    rb_define_module_function(native_io, "roundtrip", native_roundtrip, 5);
#endif
#ifdef ROBIN_NATIVE_GVL
    VALUE native_gvl = rb_define_module_under(robin, "NativeGVL");
    gvl_ready_key = rb_internal_thread_specific_key_create();
    rb_define_module_function(native_gvl, "start", native_gvl_start, 0);
    rb_define_module_function(native_gvl, "stop", native_gvl_stop, 0);
    rb_define_module_function(native_gvl, "running?", native_gvl_running_p, 0);
    rb_define_module_function(native_gvl, "wait_ns", native_gvl_wait_ns, 0);
#endif
}
