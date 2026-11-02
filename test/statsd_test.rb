# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class StatsdTest < Minitest::Test
  cover "Robin::Statsd*"

  def setup
    @server = UDPSocket.new
    @server.bind("127.0.0.1", 0)
    @port = @server.addr[1]
  end

  def teardown = @server.close

  def receive
    IO.select([@server], nil, nil, 2) or flunk("no packet")
    @server.recvfrom(65_535).first.split("\n")
  end

  def nothing_received?
    IO.select([@server], nil, nil, 0.05).nil?
  end

  def statsd(**) = Robin::Statsd.new(port: @port, **)

  def test_defaults
    s = Robin::Statsd.new

    assert_equal "robin.", s.prefix
    assert_equal "127.0.0.1", s.host
    assert_equal 8125, s.port
    assert_equal({}, s.tags)
    refute_predicate s, :dogstatsd?
    refute_predicate s, :distributions?
  end

  def test_dogstatsd_job_metrics
    s = statsd(tags: {env: "test"}, dogstatsd: true)

    assert_predicate s, :dogstatsd?
    assert_nil s.job_metrics({"HardJob" => {s: 3, f: 1, ms: 400.0, hist: {}}})
    # The average is over successful runs (the only ones timed).
    assert_equal ["robin.jobs.success:3|c|#env:test,class:HardJob", "robin.jobs.failure:1|c|#env:test,class:HardJob",
      "robin.jobs.perform:133.33|ms|#env:test,class:HardJob"], receive
  end

  def test_job_metrics_skips_zero_counts
    s = statsd(dogstatsd: true)
    s.job_metrics({"A" => {s: 0, f: 2, ms: 0.0, hist: {}}, "B" => {s: 1, f: 0, ms: 2.555, hist: {}}, "C" => {s: 0, f: 0, ms: 0.0, hist: {}}})

    assert_equal ["robin.jobs.failure:2|c|#class:A",
      "robin.jobs.success:1|c|#class:B", "robin.jobs.perform:2.56|ms|#class:B"], receive
  end

  def test_plain_statsd_queue_metrics
    s = statsd(prefix: "app", tags: {env: "x"})
    s.queue_metrics({"default" => {size: 4, latency: 1.5}, "a.b c" => {size: 0, latency: 0}})

    assert_equal ["app.queue.size.default:4|g", "app.queue.latency.default:1.5|g",
      "app.queue.size.a_b_c:0|g", "app.queue.latency.a_b_c:0|g"], receive
  end

  def test_plain_statsd_keeps_allowed_characters
    statsd.increment("hits", tags: {class: "Az09_-:Mod"})

    assert_equal ["robin.hits.Az09_-_Mod:1|c"], receive
  end

  def test_empty_prefix
    s = statsd(prefix: nil)
    s.gauge("g", 7)

    assert_equal "", s.prefix
    assert_equal ["g:7|g"], receive
    statsd(prefix: "").gauge("g", 8)

    assert_equal ["g:8|g"], receive
  end

  def test_increment_gauge_timing
    s = statsd(dogstatsd: true, tags: {a: "1"})
    s.increment("i")

    assert_equal ["robin.i:1|c|#a:1"], receive
    s.increment("i", 5, tags: {b: "x|y,z#w"})

    assert_equal ["robin.i:5|c|#a:1,b:x_y_z_w"], receive
    s.gauge("g", 2, tags: {a: "2"})

    assert_equal ["robin.g:2|g|#a:2"], receive
    s.timing("t", 1.23456)

    assert_equal ["robin.t:1.23|ms|#a:1"], receive
  end

  def test_distributions
    s = statsd(dogstatsd: true, distributions: true, tags: {a: "1"})

    assert_predicate s, :distributions?
    s.distribution("d", 12.3456, tags: {class: "Job"})

    assert_equal ["robin.d:12.35|d|#a:1,class:Job"], receive
    s.distribution("d", 2)

    assert_equal ["robin.d:2|d|#a:1"], receive
    error = assert_raises(ArgumentError) { statsd(distributions: true) }
    assert_equal "distributions need dogstatsd: true", error.message
    refute_predicate statsd(dogstatsd: true), :distributions?
  end

  def test_array_tags_repeat
    statsd(dogstatsd: true, tags: {env: "x"}).increment("b", tags: {tag: ["a|b", :c], none: []})

    assert_equal ["robin.b:1|c|#env:x,tag:a_b,tag:c"], receive
  end

  def test_non_string_tag_values
    statsd(dogstatsd: true, tags: {n: 1}).increment("x", tags: {sym: :a})

    assert_equal ["robin.x:1|c|#n:1,sym:a"], receive
    statsd.increment("y", tags: {n: 2})

    assert_equal ["robin.y.2:1|c"], receive
  end

  def test_dogstatsd_queue_metrics
    statsd(dogstatsd: true).queue_metrics({"q" => {size: 1, latency: 0.5}})

    assert_equal ["robin.queue.size:1|g|#queue:q", "robin.queue.latency:0.5|g|#queue:q"], receive
  end

  def test_oversized_single_line_is_sent_alone
    statsd(prefix: "").gauge("z" * 2000, 1)

    assert_equal ["#{"z" * 2000}:1|g"], receive
    assert_predicate self, :nothing_received?
  end

  def test_delivery_is_serialized_by_the_mutex
    s = statsd
    s.increment("warm")
    receive
    mutex = s.instance_variable_get(:@mutex)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      mutex.synchronize do
        locked << true
        release.pop
      end
    end
    locked.pop
    sender = Thread.new { s.increment("held") }

    assert_predicate self, :nothing_received?
    release << true
    sender.join
    holder.join

    assert_equal ["robin.held:1|c"], receive
  end

  def test_close_is_serialized_by_the_mutex
    s = statsd
    s.increment("warm")
    receive
    socket = s.instance_variable_get(:@socket)
    mutex = s.instance_variable_get(:@mutex)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      mutex.synchronize do
        locked << true
        release.pop
      end
    end
    locked.pop
    closer = Thread.new { s.close }
    sleep 0.05

    refute_predicate socket, :closed?
    release << true
    closer.join
    holder.join

    assert_predicate socket, :closed?
  end

  def test_dogstatsd_without_tags
    statsd(dogstatsd: true).increment("plain")

    assert_equal ["robin.plain:1|c"], receive
  end

  def test_empty_metrics_send_nothing
    s = statsd

    assert_nil s.job_metrics({})
    assert_nil s.queue_metrics({})
    assert_predicate self, :nothing_received?
  end

  def test_packets_are_split_below_max_size
    s = statsd(prefix: "")
    name = "x" * 700
    s.queue_metrics({name => {size: 1, latency: 2}, "y" => {size: 3, latency: 4}})
    first = receive
    second = receive

    assert_equal ["queue.size.#{name}:1|g"], first
    assert_equal ["queue.latency.#{name}:2|g", "queue.size.y:3|g", "queue.latency.y:4|g"], second
  end

  def test_packet_exactly_at_max_size_is_not_split
    a = "a" * 699 # "queue.size.<a>:1|g" + "\n" + "queue.latency.<a>:1|g" == 1432 bytes
    statsd(prefix: "").queue_metrics({a => {size: 1, latency: 1}})
    lines = receive

    assert_equal 2, lines.size
    assert_equal Robin::Statsd::MAX_PACKET, lines.join("\n").bytesize
  end

  def test_packet_one_byte_over_max_size_is_split
    a = "a" * 699
    statsd(prefix: "").queue_metrics({a => {size: 1, latency: 10}})

    assert_equal ["queue.size.#{a}:1|g"], receive
    assert_equal ["queue.latency.#{a}:10|g"], receive
  end

  def test_reuses_socket_and_close_resets_it
    s = statsd
    s.increment("a")
    socket = s.instance_variable_get(:@socket)
    s.increment("b")

    assert_same socket, s.instance_variable_get(:@socket)
    assert_equal ["robin.a:1|c"], receive
    assert_equal ["robin.b:1|c"], receive
    s.close

    assert_nil s.instance_variable_get(:@socket)
    assert_predicate socket, :closed?
    s.close
    s.increment("c")

    assert_equal ["robin.c:1|c"], receive
  end

  def test_never_raises
    s = Robin::Statsd.new(host: "invalid.invalid", port: 1)

    assert_nil s.increment("x")
    assert_nil s.instance_variable_get(:@socket)
  end

  def test_send_errors_drop_the_socket
    s = statsd
    s.increment("a")
    receive
    socket = s.instance_variable_get(:@socket)
    socket.close
    s.increment("b")

    assert_nil s.instance_variable_get(:@socket)
    s.increment("c")

    assert_equal ["robin.c:1|c"], receive
  end
end
