# frozen_string_literal: true

require_relative "test_helper"

class TopTest < RobinTest
  cover "Robin::Top*"

  NOW = 1_800_000_000_000

  # An input that's a terminal: records that it was put in raw mode.
  class FakeTTY
    attr_reader :raw_calls

    def initialize(reader)
      @reader = reader
      @raw_calls = 0
    end

    def tty? = true

    def raw
      @raw_calls += 1
      yield
    end

    def wait_readable(timeout) = @reader.wait_readable(timeout)

    def read_nonblock(*, **) = @reader.read_nonblock(*, **)
  end

  # An output with a terminal size.
  class SizedOutput < StringIO
    attr_reader :flushes

    def initialize(size = [24, 80])
      super()
      @size = size
      @flushes = 0
    end

    def flush
      @flushes += 1
      super
    end

    def winsize = @size.is_a?(Exception) ? raise(@size) : @size
  end

  def run(...)
    original = Robin.method(:now_ms)
    Robin.define_singleton_method(:now_ms) { NOW }
    super
  ensure
    Robin.define_singleton_method(:now_ms, original)
  end

  def top(**) = Robin::Top.new(config: config, **)

  def clock = Time.at(NOW / 1000).strftime("%H:%M:%S")

  def header(width = 80) = "Robin #{Robin::VERSION}".then { |l| l + " " * (width - l.size - 8) + clock }

  def tabs(view)
    names = Robin::Top::VIEWS.each_with_index.map { |n, i| (i == view) ? "[#{i + 1} #{n}]" : " #{i + 1} #{n} " }
    "#{names.join(" ")}   tab next · r refresh · q quit"
  end

  def add_process(identity, info, busy: 0, beat: NOW - 1_500, quiet: false, leader: false, rss: 0, work: {})
    redis("SADD", config.key("processes"), identity)
    redis("HSET", config.process_key(identity), "info", JSON.generate(info), "busy", busy,
      "beat", Robin.epoch_seconds(beat), "quiet", quiet.to_s, "leader", leader ? "1" : "0", "rss", rss)
    work.each { |tid, w| redis("HSET", "#{config.process_key(identity)}:work", tid, JSON.generate(w)) }
  end

  # A work entry as a heartbeat writes it: the payload as fetched (a
  # string) and run_at in epoch seconds.
  def work(queue, run_at_ms, payload)
    {"queue" => queue, "payload" => JSON.generate(payload), "run_at" => Robin.epoch_seconds(run_at_ms)}
  end

  def enqueue(queue, count, enqueued_at: NOW)
    redis("SADD", config.key("queues"), queue)
    count.times { |i| redis("LPUSH", config.key("queue", queue), JSON.generate({"class" => "J", "args" => [i], "jid" => "#{queue}#{i}", "enqueued_at" => enqueued_at})) }
  end

  def test_overview
    redis("SET", config.key("stat", "processed"), 1_234_567)
    redis("SET", config.key("stat", "failed"), 12)
    redis("ZADD", config.key("retry"), 1, "r")
    redis("ZADD", config.key("dead"), 1, "d1", 2, "d2")
    enqueue("default", 3, enqueued_at: NOW - 400)
    enqueue("mailers", 3, enqueued_at: NOW - 125_000)
    enqueue("low", 1)
    redis("SADD", config.key("paused"), "mailers")
    add_process("a", {"concurrency" => 10}, busy: 3)
    add_process("b", {"concurrency" => "5"})
    add_process("c", {})

    assert_equal [
      header, tabs(0), "",
      "Processed 1,234,567   Failed 12   Busy 3/15   Enqueued 7",
      "Scheduled 0   Retries 1   Dead 2   Processes 3",
      "",
      "QUEUE             SIZE  LATENCY",
      "default              3     0.4s",
      "mailers (paused)     3    2m 5s",
      "low                  1     0.0s"
    ], top.frame(24, 80)
  end

  def test_empty_views
    t = top

    assert_equal [header, tabs(0), "", "Processed 0   Failed 0   Busy 0/0   Enqueued 0",
      "Scheduled 0   Retries 0   Dead 0   Processes 0", "", "  No queues"], t.frame(24, 80)
    t.key("2")

    assert_equal [header, tabs(1), "", "  No processes"], t.frame(24, 80)
    t.key("3")

    assert_equal [header, tabs(2), "", "  Nothing running"], t.frame(24, 80)
  end

  def test_processes
    add_process("web.1:99:abc", {"hostname" => "web.1", "pid" => 99, "tag" => "app", "concurrency" => 10,
                                 "queues" => %w[default low], "started_at" => Robin.epoch_seconds(NOW - 7_380_000)},
      busy: 4, leader: true, quiet: true, rss: 204_800, beat: NOW - 65_000)
    add_process("w2", {"hostname" => "w2", "concurrency" => "5", "queues" => ["q"], "started_at" => Robin.epoch_seconds(NOW - 90_061_000)}, beat: NOW + 5_000)
    add_process("bare", {}, rss: 1_000)
    t = top
    t.key("2")

    assert_equal [
      header, tabs(1), "",
      "PROCESS         BUSY     RSS     UP   BEAT  STATUS         QUEUES",
      "                 0/0    1 MB      -   1.5s",
      "w2               0/5    0 MB  1d 1h   0.0s                 q",
      "web.1:99 [app]  4/10  200 MB  2h 3m  1m 5s  leader, quiet  default, low"
    ], t.frame(24, 80)
  end

  def test_busy
    work = {
      "t1" => work("q", NOW - 3_000, {"class" => "Wrapper", "display_class" => "Mail", "wrapped" => "Mailer",
                                      "args" => [{"arguments" => [1, "x"]}], "jid" => "j1"}),
      "t2" => work("secret", NOW - 3_700_000, {"class" => "Pay", "args" => ["c"], "encrypted" => 1, "jid" => "j2"})
    }
    add_process("p1", {"concurrency" => 2}, work: work)
    add_process("p2", {"concurrency" => 1}, work: {"t9" => work("", NOW - 90_061_000, {"class" => "Odd", "args" => [], "jid" => "j3"})})
    t = top
    t.key("3")

    assert_equal [
      header, tabs(2), "",
      "PROCESS  THREAD  QUEUE   JOB   RUNNING  ARGS",
      "p2       t9              Odd     1d 1h  []",
      "p1       t2      secret  Pay     1h 1m  [\"[encrypted]\"]",
      "p1       t1      q       Mail     3.0s  [1,\"x\"]"
    ], t.frame(24, 80)
  end

  def test_lines_fit_the_terminal
    enqueue("a-very-long-queue-name-that-goes-on", 1)
    lines = top.frame(8, 30)

    assert_equal 8, lines.size
    assert_equal 7, top.frame(7, 30).size
    assert(lines.all? { |l| l.size <= 30 })
    assert_equal "[1 Overview]  2 Processes   3…", lines[1]
    assert_equal "Processed 0   Failed 0   Busy…", lines[3]
    assert_equal "a-very-long-queue-name-that-g…", lines.last
    assert_equal ["Robin #{Robin::VERSION} #{clock[0, 6]}…"], top.frame(1, "Robin #{Robin::VERSION}".size + 8)
    assert_equal ["Robin #{Robin::VERSION} #{clock}"], top.frame(1, "Robin #{Robin::VERSION}".size + 9)
  end

  def test_redis_errors_show_instead_of_crashing
    Robin::Stats.singleton_class.define_method(:new) { |**| raise Robin::Redis::ConnectionError, "refused" }

    assert_equal [header, tabs(0), "", "Can't read from Redis: Robin::Redis::ConnectionError: refused", "Retrying every 7s."],
      top(interval: 7).frame(24, 80)
    assert_equal ["Can't read from Redis: Robin::Redis::ConnectionError: refused", "Retrying every 2s."], Robin::Top.new.frame(24, 80).last(2)
  ensure
    Robin::Stats.singleton_class.remove_method(:new)
  end

  def test_keys
    t = top

    assert_equal 0, t.view
    assert(t.key("3"))
    assert_equal 2, t.view
    assert(t.key("\t"))
    assert_equal 0, t.view
    assert(t.key("\t"))
    assert_equal 1, t.view
    assert(t.key("1"))
    assert_equal 0, t.view
    %w[4 0 x r].each do |other|
      assert(t.key(other))
      assert_equal 0, t.view
    end
    ["q", "Q", "\u0003", "\u0004"].each { |quit| refute t.key(quit) }
  end

  def test_run_draws_frames_until_quit
    reader, writer = IO.pipe
    writer.write("2")
    output = SizedOutput.new([5, 40])
    t = top(input: reader, output: output, interval: 0.01)
    thread = Thread.new { t.run }
    eventually { output.string.include?("[2 Processes]") }
    writer.write("rq")

    assert thread.join(5), "q quits"

    assert_equal 1, t.view
    text = output.string

    assert text.start_with?("\e[?1049h\e[?25l\e[H")
    assert text.end_with?("\e[J\e[?25h\e[?1049l")
    frames = text.delete_prefix("\e[?1049h\e[?25l").delete_suffix("\e[?25h\e[?1049l").split("\e[J")

    assert_operator frames.size, :>=, 2
    assert_equal "\e[H" + t.frame(5, 40).map { |l| "#{l}\e[K" }.join("\r\n"), frames.last
    assert_includes frames.first, "[1 Overview]"
    assert_equal frames.size + 1, output.flushes
  ensure
    reader&.close
    writer&.close
  end

  def test_run_stops_at_the_end_of_input_and_on_quit_in_a_burst
    reader, writer = IO.pipe
    writer.write("3")
    writer.close
    output = StringIO.new
    top(input: reader, output: output, interval: 5).run

    assert_equal 2, output.string.scan("\e[H").size
    assert_includes output.string, "[3 Busy]"
    reader2, writer2 = IO.pipe
    writer2.write("2q3")
    writer2.close
    t = top(input: reader2, output: StringIO.new, interval: 5)
    t.run

    assert_equal 1, t.view
    assert_equal [$stdin, $stdout], [Robin::Top.new.instance_variable_get(:@input), Robin::Top.new.instance_variable_get(:@output)]
  ensure
    [reader, reader2].each { |io| io&.close }
  end

  def test_run_uses_raw_mode_on_a_terminal
    reader, writer = IO.pipe
    writer.write("q")
    tty = FakeTTY.new(reader)
    output = StringIO.new
    top(input: tty, output: output).run

    assert_equal 1, tty.raw_calls
    assert_includes output.string, "[1 Overview]"
  ensure
    reader&.close
    writer&.close
  end

  def test_run_restores_the_terminal_after_errors
    output = StringIO.new
    input = Object.new
    input.define_singleton_method(:tty?) { raise IOError, "gone" }

    assert_raises(IOError) { top(input: input, output: output).run }
    assert_equal "\e[?1049h\e[?25l\e[?25h\e[?1049l", output.string
  end

  def test_terminal_size_falls_back
    enqueue("q" * 100, 1)
    30.times { |i| enqueue("queue#{i}", 1) }
    [[0, 80], [24, 0], Errno::ENOTTY.new].each do |size|
      reader, writer = IO.pipe
      writer.write("q")
      output = SizedOutput.new(size)
      top(input: reader, output: output).run

      assert_equal 23, output.string.scan("\r\n").size, size.inspect
      assert_includes output.string, "\r\n#{"q" * 79}…\e[K\r\n"
    ensure
      reader.close
      writer.close
    end
    reader, writer = IO.pipe
    writer.write("q")
    output = SizedOutput.new([3, 100])
    top(input: reader, output: output).run

    assert_equal 2, output.string.scan("\r\n").size
  ensure
    reader&.close
    writer&.close
  end

  # Key presses arriving faster than frames are read in one go.
  def test_reads_up_to_a_buffer_of_keys_per_frame
    size = Robin::Top::KEY_BUFFER
    [["1" * (size - 1) + "q", 1], ["1" * size + "q", 2]].each do |keys, frames|
      reader, writer = IO.pipe
      writer.write(keys)
      writer.close
      output = StringIO.new
      top(input: reader, output: output, interval: 5).run

      assert_equal frames, output.string.scan("\e[H").size, keys.size
    ensure
      reader.close
    end
  end

  def test_a_wakeup_without_keys_keeps_going
    input = Object.new
    reads = [:wait_readable, "q"]
    input.define_singleton_method(:tty?) { false }
    input.define_singleton_method(:wait_readable) { |_| true }
    input.define_singleton_method(:read_nonblock) { |_, **| reads.shift }
    output = StringIO.new
    top(input: input, output: output).run

    assert_equal 2, output.string.scan("\e[H").size
  end

  def test_redraws_while_waiting_for_keys
    input = Object.new
    waits = []
    ready = [false, true]
    input.define_singleton_method(:tty?) { false }
    input.define_singleton_method(:wait_readable) { |timeout| waits << timeout && ready.shift }
    input.define_singleton_method(:read_nonblock) { |_, **| "q" }
    output = StringIO.new
    top(input: input, output: output, interval: 3).run

    assert_equal [3, 3], waits
    assert_equal 2, output.string.scan("\e[H").size
  end

  def test_big_numbers_get_separators
    stats = Struct.new(:processed, :failed, :workers_size, :enqueued, :scheduled_size, :retry_size, :dead_size)
      .new(1_000, 2_000, 0, 3_000, 4_000, 5_000, 6_000)
    procs = Array.new(1_000) { {"concurrency" => 1} }
    snap = Robin::Top::Snapshot.new(stats, [["q", 7_000, 0, false]], procs, [], NOW)
    original = Robin::Top::Snapshot.method(:take)
    Robin::Top::Snapshot.define_singleton_method(:take) { |_| snap }

    assert_equal ["Processed 1,000   Failed 2,000   Busy 0/1000   Enqueued 3,000",
      "Scheduled 4,000   Retries 5,000   Dead 6,000   Processes 1,000", "", "QUEUE   SIZE  LATENCY", "q      7,000     0.0s"],
      top.frame(24, 80).drop(3)
  ensure
    Robin::Top::Snapshot.define_singleton_method(:take, original)
  end

  # A snapshot reads the config it's given, all of it when it's taken (not
  # as a frame goes through it).
  def test_a_snapshot_reads_its_config_when_taken
    alt = Robin::Config.new
    alt.redis = {url: REDIS_URL}
    alt.key_prefix = "#{key_prefix_for_test}alt:"
    alt.redis do |c|
      c.call("SET", alt.key("stat", "processed"), 5)
      c.call("SADD", alt.key("queues"), "q")
      c.call("SADD", alt.key("paused"), "q")
      c.call("LPUSH", alt.key("queue", "q"), JSON.generate({"class" => "J", "args" => [], "jid" => "j", "enqueued_at" => NOW}))
      c.call("SADD", alt.key("processes"), "p1")
      c.call("HSET", alt.process_key("p1"), "info", "{}", "busy", 1, "beat", Robin.epoch_seconds(NOW))
      c.call("HSET", "#{alt.process_key("p1")}:work", "t1", JSON.generate(work("q", NOW, {"class" => "J", "args" => [], "jid" => "j"})))
    end
    snap = Robin::Top::Snapshot.take(alt)
    alt.redis { |c| c.call("DEL", alt.key("processes"), "#{alt.process_key("p1")}:work") }

    assert_equal 5, snap.stats.processed
    assert_equal [["q", 1, 0.0, true]], snap.queues
    assert_equal ["p1"], snap.processes.map(&:identity)
    assert_equal ["p1"], snap.work.map(&:first)
  ensure
    alt&.redis_pool&.shutdown
  end

  def test_durations
    t = top

    {0 => "0.0s", -5 => "0.0s", 59.94 => "59.9s", 60 => "1m 0s", 3599 => "59m 59s", 3600 => "1h 0m",
     86_399 => "23h 59m", 86_400 => "1d 0h", 200_000 => "2d 7h", 60.5 => "1m 0s", 172_799 => "1d 23h",
     90_000 => "1d 1h", 93_599 => "1d 1h"}.each do |seconds, text|
      assert_equal text, t.send(:duration, seconds), seconds
    end
    assert_equal "0.0s", t.send(:duration, nil)
    assert_equal "1,000", t.send(:number, 1000)
    assert_equal "999", t.send(:number, 999)
    assert_equal "0", t.send(:number, nil)
    assert_equal "2 MB", t.send(:megabytes, 1536)
  end
end
