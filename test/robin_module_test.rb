# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class RobinModuleTest < RobinTest
  cover "Robin.config"
  cover "Robin.utf8"
  cover "Robin.pristine"
  cover "Robin.shutdown?"
  cover "Robin.remember_raw"
  cover "Robin.config="
  cover "Robin.eager_load!"
  cover "Robin.configure"
  cover "Robin.configure_server"
  cover "Robin.configure_client"
  cover "Robin.server?"
  cover "Robin.server!"
  cover "Robin.configure_embed"
  cover "Robin.redis"
  cover "Robin.logger"
  cover "Robin.dump_json"
  cover "Robin.load_json"
  cover "Robin.now_ms"
  cover "Robin.utf8"
  cover "Robin.generate_jid"
  cover "Robin.leader?"
  cover "Robin.cancel!"
  cover "Robin.hostname"

  def teardown
    Robin.instance_variable_set(:@server, nil)
    super
  end

  def test_hostname
    assert_equal "worker.1", Robin.hostname(env: {"DYNO" => "worker.1"})
    assert_equal Socket.gethostname, Robin.hostname(env: {})
    assert_equal Socket.gethostname, Robin.hostname
  end

  def test_config_is_memoized_and_replaceable
    Robin.instance_variable_set(:@config, nil)
    first = Robin.config

    assert_instance_of Robin::Config, first
    assert_same first, Robin.config
    replacement = Robin::Config.new
    Robin.config = replacement

    assert_same replacement, Robin.config
  ensure
    Robin.config = Robin::Config.new.tap do |c|
      c.redis = {url: REDIS_URL}
      c.key_prefix = key_prefix_for_test
      c.logger = Logger.new(nil)
    end
  end

  def test_configure_blocks
    yielded = []
    Robin.configure { |c| yielded << [:all, c] }
    Robin.configure_server { |c| yielded << [:server, c] }
    Robin.configure_client { |c| yielded << [:client, c] }

    assert_equal [[:all, config], [:client, config]], yielded
    refute_predicate Robin, :server?
    assert Robin.server!

    assert_true Robin.server?
    yielded.clear
    Robin.configure_server { |c| yielded << [:server, c] }
    Robin.configure_client { |c| yielded << [:client, c] }

    assert_equal [[:server, config]], yielded
    Robin.instance_variable_set(:@server, nil)

    assert_false Robin.server?
  end

  def test_configure_embed
    yielded = nil
    embedded = Robin.configure_embed { |c| yielded = c }

    assert_instance_of Robin::Embedded, embedded
    assert_same config, yielded
    assert_same config, embedded.config
    assert_instance_of Robin::Embedded, Robin.configure_embed
  end

  def test_redis_and_logger
    assert_equal "PONG", Robin.redis { |c| c.call("PING") }
    assert_same config.logger, Robin.logger
  end

  def test_json
    assert_equal '{"a":[1,null]}', Robin.dump_json({"a" => [1, nil]})
    assert_equal({"a" => [1, nil]}, Robin.load_json('{"a":[1,null]}'))
  end

  def test_utf8
    {
      "café" => "café",
      String.new("bad \xFF", encoding: "UTF-8") => "bad \uFFFD",
      "caf\xC3\xA9 \xFF".b => "café \uFFFD",
      String.new("caf\xE9", encoding: "ISO-8859-1") => "café",
      "café".encode("UTF-16LE") => "café",
      String.new("x\x81", encoding: "Windows-1252") => "x\uFFFD", # undefined in the source
      String.new("x\x82", encoding: "Shift_JIS") => "x\uFFFD", # invalid in the source
      String.new("caf\xC3\xA9", encoding: "UTF-7") => "café" # no converter: read as UTF-8
    }.each do |input, expected|
      frozen = input.freeze
      output = Robin.utf8(frozen)

      assert_equal expected, output, input.inspect
      assert_equal Encoding::UTF_8, output.encoding
      assert_equal input.encoding, frozen.encoding # never modified in place
      refute_same frozen, output
    end
  end

  def test_now_ms
    before = (Time.now.to_f * 1000).floor
    now = Robin.now_ms
    after = (Time.now.to_f * 1000).ceil

    assert_operator now, :>=, before
    assert_operator now, :<=, after
    assert_kind_of Integer, Robin.now_ms
  end

  def test_generate_jid
    jid = Robin.generate_jid

    assert_match(/\A\h{24}\z/, jid)
    refute_equal jid, Robin.generate_jid
  end

  def test_jids_come_from_one_random_read_per_batch
    Thread.new do
      reads = []
      SecureRandom.singleton_class.alias_method(:__robin_hex, :hex)
      SecureRandom.define_singleton_method(:hex) { |n| reads << n && __robin_hex(n) }
      begin
        jids = Array.new((Robin::JID_BATCH * 2) + 1) { Robin.generate_jid }

        assert_equal [12 * Robin::JID_BATCH] * 3, reads
        assert_equal jids.size, jids.uniq.size
        assert(jids.all? { |j| j.match?(/\A\h{24}\z/) })
      ensure
        SecureRandom.singleton_class.alias_method(:hex, :__robin_hex)
        SecureRandom.singleton_class.remove_method(:__robin_hex)
      end
    end.join
  end

  def test_jids_are_per_thread_and_never_reused_after_a_fork
    mine = Robin.generate_jid
    theirs = Thread.new { [Robin.generate_jid, Thread.current[:robin_jids].offset] }.value

    refute_equal mine, theirs.first
    assert_equal 24, theirs.last
    batch = Thread.current[:robin_jids]
    next_jid = batch.hex.byteslice(batch.offset, 24)
    batch.pid = -1 # as in a forked child, whose pid differs

    refute_equal next_jid, Robin.generate_jid
    assert_equal [Process.pid, 24], Thread.current[:robin_jids].to_h.values_at(:pid, :offset)
  end

  def test_leader
    refute_predicate Robin, :leader?
    elector = Object.new
    elector.define_singleton_method(:leader?) { true }
    Robin::Leader.register(config, elector)

    assert_predicate Robin, :leader?
  ensure
    Robin::Leader.unregister(config)
  end

  def test_cancel
    original = Robin.method(:now_ms)
    Robin.define_singleton_method(:now_ms) { 1_000 }

    assert Robin.cancel!("abc")
    Robin.cancel!("short", ttl: 1)

    assert_equal "86401000", redis("ZSCORE", config.key("cancelled"), "abc")
    assert_equal "2000", redis("ZSCORE", config.key("cancelled"), "short")
  ensure
    Robin.define_singleton_method(:now_ms, original)
  end

  def test_eager_load_loads_autoloads
    path = File.join(Dir.pwd, "tmp", "robin_eager_#{Process.pid}.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "module Robin; module EagerProbe; end; end\n")
    Robin.autoload(:EagerProbe, path)
    Robin.eager_load!

    assert_nil Robin.autoload?(:EagerProbe)
    assert Robin.const_defined?(:EagerProbe, false)
  ensure
    Robin.send(:remove_const, :EagerProbe) if Robin.const_defined?(:EagerProbe, false)
    File.delete(path) if path && File.exist?(path)
  end

  # Robin::Testing switches pushes to test mode when loaded, so eager
  # loading must never touch it.
  def test_eager_load_skips_testing
    saved = Robin.const_defined?(:Testing, false) && !Robin.autoload?(:Testing) && Robin.send(:remove_const, :Testing)
    unless Robin.autoload?(:Testing)
      Robin.autoload(:Testing, File.join(Dir.pwd, "tmp", "robin_testing_must_not_load.rb"))
    end
    Robin.eager_load!

    assert Robin.autoload?(:Testing)
  ensure
    if saved
      Robin.send(:remove_const, :Testing) if Robin.const_defined?(:Testing, false)
      Robin.const_set(:Testing, saved)
    end
  end

  def test_utf8_scrubs_invalid_utf8
    invalid = (+"ok \xFF").force_encoding(Encoding::UTF_8)
    result = Robin.utf8(invalid)

    assert_equal "ok \uFFFD", result
    assert_equal Encoding::UTF_8, result.encoding
    refute_same invalid, result
  end

  def test_utf8_tags_binary_as_utf8_and_scrubs_it
    assert_equal "h\u00e9 \uFFFD", Robin.utf8("h\xC3\xA9 \xFF".b)
    assert_equal Encoding::UTF_8, Robin.utf8("x".b).encoding
  end

  def test_utf8_transcodes_other_encodings
    latin = (+"caf\xE9").force_encoding(Encoding::ISO_8859_1)

    assert_equal "caf\u00e9", Robin.utf8(latin)
    assert_equal "\uFFFD", Robin.utf8((+"\x81").force_encoding(Encoding::Shift_JIS))
  end

  def test_utf8_without_a_converter_scrubs_the_bytes
    dummy = (+"ok \xFF").force_encoding(Encoding::UTF_7)

    assert_equal "ok \uFFFD", Robin.utf8(dummy)
  end

  def test_pristine_reparses_the_remembered_raw_json
    raw = '{"args":[{"a":1}],"jid":"j"}'
    payload = JSON.parse(raw)

    assert_same payload, Robin.remember_raw(payload, raw)
    payload.fetch("args").first["a"] = 2
    pristine = Robin.pristine(payload)

    assert_equal({"args" => [{"a" => 1}], "jid" => "j"}, pristine)
    refute_same payload, pristine
  end

  def test_pristine_without_raw_returns_the_payload
    payload = {"jid" => "j"}

    assert_same payload, Robin.pristine(payload)
  end

  def raise_with_cause(error, cause)
    raise error, cause: cause
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  def test_shutdown_detects_shutdown_and_errors_it_caused
    shutdown = Robin::Shutdown.new
    wrapped = raise_with_cause(ArgumentError.new("cleanup"), shutdown)
    twice = raise_with_cause(RuntimeError.new("outer"), wrapped)

    assert Robin.shutdown?(shutdown)
    assert Robin.shutdown?(wrapped)
    assert Robin.shutdown?(twice)
    assert Robin.shutdown?(Class.new(Robin::Shutdown).new)
    assert_false Robin.shutdown?(RuntimeError.new("plain"))
    refute Robin.shutdown?(raise_with_cause(RuntimeError.new("x"), Interrupt.new))
    refute Robin.shutdown?(nil)
  end

  def test_shutdown_survives_cyclic_causes
    a = RuntimeError.new("a")
    b = RuntimeError.new("b")
    a.define_singleton_method(:cause) { b }
    b.define_singleton_method(:cause) { a }

    assert_false Robin.shutdown?(a)
  end
end
