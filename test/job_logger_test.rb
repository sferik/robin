# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class JobLoggerTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::JobLogger*"
  cover "Robin::Context*"

  TIME = Time.utc(2026, 1, 2, 3, 4, 5.678r)

  def teardown
    Thread.current[Robin::Context::KEY] = nil
    super
  end

  def test_context_with_merges_and_restores
    Robin::Context.current[:a] = 1
    seen = nil
    result = Robin::Context.with(b: 2) do
      seen = Robin::Context.current.dup
      :value
    end

    assert_equal :value, result
    assert_equal({a: 1, b: 2}, seen)
    assert_equal({a: 1}, Robin::Context.current)
  end

  def test_context_restores_after_exception_and_is_per_thread
    assert_raises(RuntimeError) { Robin::Context.with(x: 1) { raise "boom" } }
    assert_empty Robin::Context.current
    assert_same Robin::Context.current, Thread.current[:robin_context]
    other = Thread.new { Robin::Context.current[:t] = 1 }
    other.join

    assert_empty Robin::Context.current
  end

  def test_tid_is_stable_per_thread
    tid = Robin::JobLogger.tid

    assert_equal tid, Robin::JobLogger.tid
    fresh, expected = Thread.new { [Robin::JobLogger.tid, (Thread.current.object_id ^ Process.pid).to_s(36)] }.value

    assert_equal expected, fresh
    refute_equal tid, Thread.new { Robin::JobLogger.tid }.value
  end

  def test_text_formatter
    f = Robin::JobLogger::Formatter.new
    tid = Robin::JobLogger.tid

    assert_equal "2026-01-02T03:04:05.678Z pid=#{Process.pid} tid=#{tid} INFO: hello\n", f.call("INFO", TIME, nil, "hello")
    Robin::Context.with(class: "Foo", jid: "abc") do
      assert_equal "2026-01-02T03:04:05.678Z pid=#{Process.pid} tid=#{tid} class=Foo jid=abc WARN: [1, 2]\n",
        f.call("WARN", TIME.getlocal("+05:00"), "prog", [1, 2])
    end
  end

  def test_formatters_inspect_non_strings_but_not_string_subclasses
    sub = Class.new(String).new("sub")
    text = Robin::JobLogger::Formatter.new
    json = Robin::JobLogger::JSONFormatter.new

    assert text.call("INFO", TIME, nil, :sym).end_with?(" INFO: :sym\n")
    assert text.call("INFO", TIME, nil, nil).end_with?(" INFO: nil\n")
    assert text.call("INFO", TIME, nil, sub).end_with?(" INFO: sub\n")
    assert_equal ":sym", JSON.parse(json.call("INFO", TIME, nil, :sym))["msg"]
    assert_equal "sub", JSON.parse(json.call("INFO", TIME, nil, sub))["msg"]
  end

  def test_json_formatter
    f = Robin::JobLogger::JSONFormatter.new
    line = f.call("INFO", TIME, nil, "hi")

    assert line.end_with?("}\n")
    assert_equal({"ts" => "2026-01-02T03:04:05.678Z", "pid" => Process.pid, "tid" => Robin::JobLogger.tid,
                  "lvl" => "INFO", "msg" => "hi"}, JSON.parse(line))
    Robin::Context.with(jid: "j") do
      parsed = JSON.parse(f.call("ERROR", TIME.getlocal("-02:00"), nil, {a: 1}))

      assert_equal({"jid" => "j"}, parsed["ctx"])
      assert_equal "{a: 1}", parsed["msg"]
      assert_equal "2026-01-02T03:04:05.678Z", parsed["ts"]
    end
  end

  def test_json_formatter_scrubs_invalid_strings
    f = Robin::JobLogger::JSONFormatter.new
    Robin::Context.with(jid: "j\xFF".b, n: 1, list: ["\xFF".b, {k: ["x\xFF".b, nil]}]) do
      parsed = JSON.parse(f.call("WARN", TIME, nil, "bad \xFF".b))

      assert_equal "bad \uFFFD", parsed["msg"]
      assert_equal({"jid" => "j\uFFFD", "n" => 1, "list" => ["\uFFFD", {"k" => ["x\uFFFD", nil]}]}, parsed["ctx"])
      assert_equal "\uFFFD", JSON.parse(f.call("WARN", TIME, nil, Struct.new(:to_s, :inspect).new("", "\xFF".b)))["msg"]
    end
  end

  def test_call_logs_start_and_done_with_context
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = ->(sev, _t, _p, msg) { "#{sev} #{Robin::Context.current.inspect} #{msg}\n" }
    config.logger = logger
    payload = {"class" => "Foo", "jid" => "j1", "bid" => "b1", "tags" => %w[a b]}
    result = Robin::JobLogger.new(config).call(payload) { :ok }
    lines = io.string.lines

    assert_equal :ok, result
    assert_equal 2, lines.size
    assert_equal %(INFO {class: "Foo", jid: "j1", bid: "b1", tags: "a,b"} start\n), lines[0]
    assert_match(/\AINFO \{class: "Foo", jid: "j1", bid: "b1", tags: "a,b", elapsed: "\d+\.\d{3}"\} done\n\z/, lines[1])
    assert_empty Robin::Context.current
  end

  def test_call_uses_display_class_and_skips_missing_extras
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = ->(_sev, _t, _p, msg) { "#{Robin::Context.current.keys.join(",")}|#{Robin::Context.current[:class]} #{msg}\n" }
    config.logger = logger
    Robin::JobLogger.new(config).call({"class" => "W", "display_class" => "Real", "jid" => "j", "tags" => []}) { nil }
    Robin::JobLogger.new(config).call({"class" => "W", "jid" => "j", "tags" => "x"}) { nil }

    assert_equal ["class,jid|Real start\n", "class,jid,elapsed|Real done\n", "class,jid|W start\n", "class,jid,elapsed|W done\n"], io.string.lines
  end

  def test_call_tolerates_sparse_payloads
    seen = []
    config.logger = Logger.new(nil)
    Robin::JobLogger.new(config).call({}) { seen << Robin::Context.current.dup }
    Robin::JobLogger.new(config).call({"class" => "A", "bid" => nil, "tags" => nil}) { seen << Robin::Context.current.dup }
    tags = Class.new(Array).new(%w[x y])
    Robin::JobLogger.new(config).call({"class" => "A", "tags" => tags}) { seen << Robin::Context.current.dup }

    assert_equal [{class: nil, jid: nil}, {class: "A", jid: nil}, {class: "A", jid: nil, tags: "x,y"}], seen
  end

  def test_elapsed_is_measured_from_job_start
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = ->(_sev, _t, _p, msg) { "#{msg} #{Robin::Context.current[:elapsed]}\n" }
    config.logger = logger
    Robin::JobLogger.new(config).call({"class" => "A"}) { sleep 0.02 }
    elapsed = io.string.lines.last.split.last.to_f

    assert_operator elapsed, :>=, 0.02
    assert_operator elapsed, :<, 1
  end

  def test_call_logs_fail_and_reraises
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = ->(sev, _t, _p, msg) { "#{sev} #{Robin::Context.current[:elapsed].class} #{msg}\n" }
    config.logger = logger
    error = Class.new(Exception) # rubocop:disable Lint/InheritException

    assert_raises(error) { Robin::JobLogger.new(config).call({"class" => "F", "jid" => "j"}) { raise error } }
    assert_equal ["INFO NilClass start\n", "INFO String fail\n"], io.string.lines
  end

  def severities_logged(payload, fail: false)
    io = StringIO.new
    config.logger = Logger.new(io, level: Logger::DEBUG, formatter: ->(sev, _t, _p, msg) { "#{sev} #{msg}\n" })
    contexts = []
    job = lambda do
      contexts << Robin::Context.current[:jid]
      raise "boom" if fail
    end
    begin
      Robin::JobLogger.new(config).call({"class" => "A", "jid" => "j"}.merge(payload), &job)
    rescue RuntimeError
      nil
    end
    [io.string.lines(chomp: true), contexts]
  end

  def test_per_job_log_level
    assert_equal [["DEBUG start", "DEBUG done"], ["j"]], severities_logged({"log_level" => "debug"})
    assert_equal [["DEBUG start", "DEBUG done"], ["j"]], severities_logged({"log_level" => :debug})
    assert_equal [["WARN start", "WARN fail"], ["j"]], severities_logged({"log_level" => "warn"}, fail: true)
    assert_equal [["ERROR start", "ERROR done"], ["j"]], severities_logged({"log_level" => "error"})
    assert_equal [["INFO start", "INFO done"], ["j"]], severities_logged({"log_level" => "info"})
    assert_equal [["INFO start", "INFO done"], ["j"]], severities_logged({"log_level" => "verbose"})
    assert_equal [["INFO start", "INFO done"], ["j"]], severities_logged({"log_level" => nil})
  end

  def test_logging_can_be_turned_off_but_keeps_the_context
    assert_equal [[], ["j"]], severities_logged({"logging" => false})
    assert_equal [[], ["j"]], severities_logged({"logging" => false}, fail: true)
    assert_equal [["INFO start", "INFO done"], ["j"]], severities_logged({"logging" => nil})
    assert_equal %w[debug info warn error], Robin::JobLogger::LEVELS
  end

  def test_lines_the_logger_would_drop_cost_nothing
    io = StringIO.new
    config.logger = Logger.new(io, level: Logger::WARN, formatter: ->(sev, _t, _p, msg) { "#{sev} #{msg}\n" })
    logger = Robin::JobLogger.new(config)

    logger.define_singleton_method(:elapsed) { |_start| flunk "timed a job nobody logs" }
    jid = nil
    result = logger.call({"class" => "A", "jid" => "j"}) do
      jid = Robin::Context.current[:jid]
      :result
    end

    assert_equal [:result, "j", ""], [result, jid, io.string]
    logger.singleton_class.remove_method(:elapsed)
    logger.call({"class" => "A", "jid" => "j", "log_level" => "warn"}) { nil }

    assert_equal ["WARN start", "WARN done"], io.string.lines(chomp: true)
  end

  def test_works_with_any_logger_that_answers_level_predicates
    lines = []
    quiet = Object.new
    quiet.define_singleton_method(:info?) { false }
    quiet.define_singleton_method(:debug?) { true }
    quiet.define_singleton_method(:debug) { |msg| lines << msg }
    config.logger = quiet
    logger = Robin::JobLogger.new(config)
    logger.call({"class" => "A", "jid" => "j"}) { nil }
    logger.call({"class" => "A", "jid" => "j", "log_level" => "debug"}) { nil }

    assert_equal %w[start done], lines
  end

  def test_context_for
    assert_equal({class: "A", jid: "j"}, Robin::JobLogger.context_for({"class" => "A", "jid" => "j", "tags" => []}))
    assert_equal({class: "D", jid: "j", bid: "b", tags: "x,y"},
      Robin::JobLogger.context_for({"class" => "A", "display_class" => "D", "jid" => "j", "bid" => "b", "tags" => %w[x y]}))
    assert_equal({class: "A", jid: nil}, Robin::JobLogger.context_for({"class" => "A", "tags" => "not-a-list"}))
  end

  def test_elapsed_format
    logger = Robin::JobLogger.new(config)
    clock = ->(id) { (id == Process::CLOCK_MONOTONIC) ? 101.23456 : 0 }

    assert_equal "1.235", stub_method(Process, :clock_gettime, clock) { logger.send(:elapsed, 100.0) }
  end
end
