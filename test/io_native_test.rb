# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "robin"
require "minitest/autorun"
require "minitest/strict"
require "socket"

begin
  require "robin_resp/robin_resp"
rescue LoadError
  nil
end

# Robin::Redis::NativeIO.fill, the C extension's socket reader.
class IONativeTest < Minitest::Test
  def setup
    skip "native extension not compiled (run `rake compile`)" unless defined?(Robin::Redis::NativeIO)
    # C only: JRuby has no GVL to save releasing, so the Java extension
    # leaves sending to Ruby.
    skip "NativeIO.roundtrip is C only" if name.include?("roundtrip") && !Robin::Redis::NativeIO.respond_to?(:roundtrip)
    @ours, @theirs = UNIXSocket.pair
  end

  def teardown
    [@ours, @theirs].each { |s| s&.close unless s&.closed? }
  end

  def fill(buf, timeout = 1, io: @ours) = Robin::Redis::NativeIO.fill(io, buf, timeout)

  def elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  def test_appends_what_arrived_and_returns_its_size
    @theirs.write("+OK\r\n")
    buf = "head".b

    assert_equal 5, fill(buf)
    assert_equal "head+OK\r\n", buf
    assert_equal Encoding::BINARY, buf.encoding
  end

  def test_waits_for_the_reply
    buf = "".b
    writer = Thread.new do
      sleep 0.05
      @theirs.write(":1\r\n")
    end

    assert_operator elapsed { assert_equal 4, fill(buf, 2) }, :>=, 0.04
    writer.join
  end

  def test_reads_long_replies_a_chunk_at_a_time
    writer = Thread.new { @theirs.write("x" * 40_000) }
    buf = "".b
    reads = []
    reads << fill(buf) while buf.bytesize < 40_000
    writer.join

    assert_equal 40_000, reads.sum
    assert_operator reads.max, :<=, 16_384
  end

  def test_nil_when_the_server_closed_the_connection
    @theirs.close

    assert_nil fill(+"")
  end

  def test_false_when_nothing_arrives_in_time
    took = elapsed { assert_false fill(+"", 0.05) }

    assert_operator took, :>=, 0.04
    assert_operator took, :<, 1
  end

  def test_timeouts_of_zero_or_less_only_take_what_is_there
    assert_false fill(+"", 0)
    assert_false fill(+"", -1)
    @theirs.write("+x\r\n")

    assert_equal 4, fill(+"", 0)
  end

  def test_short_and_huge_timeouts
    @theirs.write("+a\r\n")

    assert_equal 4, fill(+"", 1e12)
    assert_false fill(+"", 0.0004), "a fraction of a millisecond still waits one"
  end

  def test_failed_reads_raise
    File.open(__dir__) do |dir|
      assert_raises(Errno::EISDIR) { fill(+"", 1, io: dir) }
    end
    @ours.close

    assert_raises(IOError) { fill(+"") }
  end

  def test_thread_raise_interrupts_the_wait
    waiter = Thread.new { fill(+"", 30) }
    waiter.report_on_exception = false
    sleep 0.1 # (a thread waiting without the GVL reports itself running)
    took = elapsed do
      waiter.raise(RuntimeError, "stop waiting")
      error = assert_raises(RuntimeError) { waiter.value }
      assert_equal "stop waiting", error.message
    end

    assert_operator took, :<, 5
  end

  def test_other_interruptions_keep_waiting
    waiter = Thread.new { fill(buf = +"", 5) && buf }
    sleep 0.1
    waiter.wakeup
    sleep 0.1

    assert_predicate waiter, :alive?
    @theirs.write("+late\r\n")

    assert_equal "+late\r\n", waiter.value
  end

  def test_stale_while_nothing_is_waiting_to_be_read
    refute Robin::Redis::NativeIO.stale?(@ours)
    @theirs.write("+push\r\n")

    assert Robin::Redis::NativeIO.stale?(@ours), "bytes nothing asked for"
    assert_equal 7, fill(+""), "only peeked at"
    @theirs.close

    assert Robin::Redis::NativeIO.stale?(@ours), "closed by the server"
  end

  def test_stale_when_the_socket_fails
    sock = Socket.new(:INET, :STREAM)

    assert Robin::Redis::NativeIO.stale?(sock), "not connected"
  ensure
    sock&.close
  end

  def test_buffer_must_be_a_string
    assert_raises(TypeError) { fill(nil) }
  end

  # -- roundtrip: check, write and read in one call ----------------------------

  def roundtrip(data, buf = +"", write_timeout: 1, read_timeout: 1, io: @ours)
    Robin::Redis::NativeIO.roundtrip(io, data, buf, write_timeout, read_timeout)
  end

  def test_roundtrip_sends_and_reads_the_reply
    replier = Thread.new do
      request = @theirs.readpartial(100)
      @theirs.write("+PONG\r\n")
      request
    end
    buf = "head".b

    assert_equal 7, roundtrip("*1\r\n$4\r\nPING\r\n", buf)
    assert_equal "head+PONG\r\n", buf
    assert_equal "*1\r\n$4\r\nPING\r\n", replier.value
  end

  def test_roundtrip_reports_a_stale_connection_without_sending
    @theirs.write("+push\r\n")

    assert_equal :stale, roundtrip("PING")
    assert_equal :wait_readable, @theirs.read_nonblock(10, exception: false), "nothing was sent"
  end

  def test_roundtrip_waits_to_write_more
    data = "x" * 4_000_000
    reader = Thread.new do
      got = +""
      got << @theirs.readpartial(65_536) while got.bytesize < data.bytesize
      @theirs.write(":1\r\n")
      got.bytesize
    end

    assert_equal 4, roundtrip(data, write_timeout: 5, read_timeout: 5)
    assert_equal data.bytesize, reader.value
  end

  def test_roundtrip_reports_how_much_a_timed_out_write_sent
    written, errno = roundtrip("x" * 4_000_000, write_timeout: 0.05)

    assert_operator written, :>, 0
    assert_nil errno
  end

  def test_roundtrip_reports_a_failed_write
    @ours.shutdown(Socket::SHUT_WR)

    assert_equal [0, Errno::EPIPE::Errno], roundtrip("PING")
  end

  def test_roundtrip_read_results_match_fill
    @theirs.close

    assert_equal :stale, roundtrip("PING"), "closed before it started"
    @ours, @theirs = UNIXSocket.pair

    assert_false roundtrip("PING", read_timeout: 0.05)
    closer = Thread.new { @theirs.readpartial(10) && @theirs.close }

    assert_nil roundtrip("PING")
    closer.join
  end

  def test_roundtrip_raises_when_the_read_fails
    server = TCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.addr[1])
    peer = server.accept
    resetter = Thread.new do
      peer.readpartial(10)
      peer.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii")) # close with a reset
      peer.close
    end

    assert_raises(Errno::ECONNRESET) { roundtrip("PING", io: client) }
    resetter.join
  ensure
    [client, server].each { |s| s&.close }
  end

  def test_roundtrip_resumes_after_other_interruptions
    data = "x" * 4_000_000
    waiter = Thread.new { roundtrip(data, buf = +"", write_timeout: 5, read_timeout: 5) && buf }
    sleep 0.1
    waiter.wakeup # while writing
    got = +""
    got << @theirs.readpartial(65_536) while got.bytesize < data.bytesize
    sleep 0.1
    waiter.wakeup # while waiting for the reply
    sleep 0.1

    assert_predicate waiter, :alive?
    @theirs.write("+late\r\n")

    assert_equal "+late\r\n", waiter.value
  end

  def test_thread_raise_interrupts_a_roundtrip
    waiter = Thread.new { roundtrip("PING", read_timeout: 30) }
    waiter.report_on_exception = false
    sleep 0.1
    waiter.raise(RuntimeError, "stop")

    assert_equal "stop", assert_raises(RuntimeError) { waiter.value }.message
    data = +"PING"
    roundtrip(data, read_timeout: 0)
    data << "!" # unlocked again
  end

  def test_roundtrip_arguments_must_be_strings
    assert_raises(TypeError) { roundtrip(nil) }
    assert_raises(TypeError) { roundtrip("PING", nil) }
  end
end
