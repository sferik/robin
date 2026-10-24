# frozen_string_literal: true

require_relative "test_helper"

class SecretJob
  include Robin::Job

  robin_options encrypt: true, retry: 1
  SEEN = Queue.new
  def perform(card, amount)
    SEEN << [card, amount]
    raise "declined" if amount < 0
  end
end

class EncryptionTest < RobinTest
  cover "Robin::Encryption*"

  KEY1 = "a" * 32
  KEY2 = "b" * 64 # hex
  KEY3 = ["c" * 32].pack("m0") # base64

  def setup
    super
    config.encryption_keys = {1 => KEY1}
  end

  def enc = Robin::Encryption

  def client_mw = Robin::Encryption::ClientMiddleware.new.tap { |m| m.config = config }

  def server_mw = Robin::Encryption::ServerMiddleware.new.tap { |m| m.config = config }

  def test_keys_normalizes_versions_and_formats
    config.encryption_keys = {"1" => KEY1, 2 => KEY2, 3 => KEY3}
    keys = enc.keys(config)

    assert_equal [1, 2, 3], keys.keys
    assert_equal KEY1.b, keys[1]
    assert_equal Encoding::BINARY, keys[1].encoding
    assert_equal ["b" * 64].pack("H*"), keys[2]
    assert_equal "c" * 32, keys[3]
  end

  def test_keys_requires_configuration
    config.encryption_keys = nil
    error = assert_raises(Robin::Encryption::Error) { enc.keys(config) }
    assert_match(/encryption_keys/, error.message)
    config.encryption_keys = {}
    assert_raises(Robin::Encryption::Error) { enc.keys(config) }
  end

  def test_normalize_key_rejects_bad_keys
    ["short", "z" * 64, ["x" * 31].pack("m0"), "!!!" * 20, nil].each do |bad|
      error = assert_raises(Robin::Encryption::Error, bad.inspect) { enc.normalize_key(bad) }
      assert_match(/32 bytes/, error.message)
    end
  end

  def test_normalize_key_accepts_symbols_and_unicode_lengths
    assert_equal ("k" * 32).b, enc.normalize_key(("k" * 32).to_sym)
    # 32 bytes but 16 characters: bytesize, not length, counts
    assert_equal ("é" * 16).b, enc.normalize_key("é" * 16)
  end

  def test_encrypt_and_decrypt_round_trip_with_newest_key
    config.encryption_keys = {1 => KEY1, 3 => KEY3, 2 => KEY2}
    version, blob = enc.encrypt(config, ["card", 5, {"a" => nil}], "jid1")

    assert_equal 3, version
    raw = blob.unpack1("m0")

    assert_operator raw.bytesize, :>, Robin::Encryption::IV_BYTES + Robin::Encryption::TAG_BYTES
    assert_equal ["card", 5, {"a" => nil}], enc.decrypt(config, version, blob, "jid1")
    refute_equal blob, enc.encrypt(config, ["card", 5, {"a" => nil}], "jid1")[1] # random IV
  end

  def test_decrypt_uses_the_requested_version
    _, old_blob = enc.encrypt(config, ["old"], "j")
    config.encryption_keys = {1 => KEY1, 2 => KEY2}

    assert_equal ["old"], enc.decrypt(config, 1, old_blob, "j")
    error = assert_raises(Robin::Encryption::Error) { enc.decrypt(config, 9, old_blob, "j") }
    assert_equal "no encryption key for version 9", error.message
  end

  def test_decrypt_rejects_tampering_and_garbage
    _, blob = enc.encrypt(config, ["x"], "jid")
    raw = blob.unpack1("m0")
    flipped = raw.dup
    flipped.setbyte(raw.bytesize - 1, raw.getbyte(raw.bytesize - 1) ^ 1)
    tag_flipped = raw.dup
    last_tag_byte = Robin::Encryption::IV_BYTES + Robin::Encryption::TAG_BYTES - 1
    tag_flipped.setbyte(last_tag_byte, raw.getbyte(last_tag_byte) ^ 1)
    iv_flipped = raw.dup
    iv_flipped.setbyte(0, raw.getbyte(0) ^ 1)
    [
      [blob, "other-jid"],
      [[flipped].pack("m0"), "jid"],
      [[tag_flipped].pack("m0"), "jid"],
      [[iv_flipped].pack("m0"), "jid"],
      # Cut short inside the tag: there's no ciphertext at all.
      [[raw.byteslice(0, Robin::Encryption::IV_BYTES + 1)].pack("m0"), "jid"],
      ["%%%not base64", "jid"]
    ].each do |bad_blob, aad|
      error = assert_raises(Robin::Encryption::Error) { enc.decrypt(config, 1, bad_blob, aad) }
      assert_equal "could not decrypt job arguments (wrong key or tampered payload)", error.message
    end
    config.encryption_keys = {1 => KEY2}
    assert_raises(Robin::Encryption::Error) { enc.decrypt(config, 1, blob, "jid") }
  end

  def test_client_middleware_encrypts_only_when_asked
    plain = {"args" => [1], "jid" => "j"}

    assert_equal :ok, client_mw.call(nil, plain, "q", nil) { :ok }
    assert_equal({"args" => [1], "jid" => "j"}, plain)
    off = {"args" => [1], "jid" => "j", "encrypt" => false}
    client_mw.call(nil, off, "q", nil) { nil }

    assert_equal [1], off["args"]

    unset = {"args" => [2], "jid" => "j", "encrypt" => true, "encrypted" => nil}
    client_mw.call(nil, unset, "q", nil) { nil }

    assert_equal 1, unset["encrypted"]

    payload = {"args" => [1, "secret"], "jid" => "j", "encrypt" => true}

    assert_equal :ok, client_mw.call(nil, payload, "q", nil) { :ok }
    assert_equal 1, payload["encrypted"]
    assert_equal 1, payload["args"].size
    refute_includes payload["args"].first, "secret"
    assert_equal [1, "secret"], enc.decrypt(config, 1, payload["args"].first, "j")

    again = payload["args"].dup
    client_mw.call(nil, payload, "q", nil) { nil }

    assert_equal again, payload["args"] # already encrypted: untouched
  end

  def test_server_middleware_decrypts_and_restores
    plain = {"args" => [1], "jid" => "j"}

    assert_equal :plain, server_mw.call(nil, plain, "q") { :plain }
    unset = {"args" => [1], "jid" => "j", "encrypted" => nil}

    assert_equal :plain, server_mw.call(nil, unset, "q") { :plain }

    version, blob = enc.encrypt(config, ["card", 5], "j")
    raw = JSON.generate({"args" => [blob], "jid" => "j", "encrypted" => version})
    payload = Robin.remember_raw(JSON.parse(raw), raw)
    seen = nil
    stored = nil
    result = server_mw.call(nil, payload, "q") do
      seen = payload["args"]
      stored = Robin.pristine(payload)["args"]
      :done
    end

    assert_equal :done, result
    assert_equal ["card", 5], seen
    assert_equal [blob], stored
    assert_equal [blob], payload["args"]
  end

  def test_only_the_last_argument_when_asked
    payload = {"jid" => "j", "args" => [7, "x", {"card" => "4242"}], "encrypt" => "last"}
    client_mw.call("C", payload, "q", nil) { nil }
    clear, blob = payload.fetch("args").first(2), payload.fetch("args").last

    assert_equal [[7, "x"], 1], [clear, payload["encrypted"]]
    assert_equal({"card" => "4242"}, enc.decrypt(config, 1, blob, "j"))
    assert_equal [7, "x", "[encrypted]"], enc.visible_args(payload)
    assert_equal [7, "x", "[encrypted]"], Robin::JobRecord.new(payload).display_args
    assert_equal [7, "x", "[encrypted]"], Robin::JobRecord.new(payload).to_h.fetch("item").fetch("args")
    stored = payload.fetch("args")
    seen = server_mw.call(nil, payload, "q") { payload["args"] }

    assert_equal [7, "x", {"card" => "4242"}], seen
    assert_same stored, payload["args"]
    lone = {"jid" => "k", "args" => [{"s" => 1}], "encrypt" => :last}
    client_mw.call("C", lone, "q", nil) { nil }

    assert_equal 1, lone["args"].size
    assert_equal [{"s" => 1}], server_mw.call(nil, lone, "q") { lone["args"] }
    pair = {"jid" => "p", "args" => [1, {"s" => 2}], "encrypt" => :last}
    client_mw.call("C", pair, "q", nil) { nil }

    assert_equal 1, pair["args"].first
    assert_equal [1, {"s" => 2}], server_mw.call(nil, pair, "q") { pair["args"] }
    assert_equal ["[encrypted]"], enc.visible_args({"args" => ["blob"], "encrypt" => true})
    # Unless only the last is encrypted, none of the arguments show.
    assert_equal ["[encrypted]"], enc.visible_args({"args" => %w[a b], "encrypt" => true})
    refute enc.last_only?({"encrypt" => true})
  end

  def test_server_middleware_restores_on_error
    version, blob = enc.encrypt(config, ["card"], "j")
    payload = {"args" => [blob], "jid" => "j", "encrypted" => version}
    assert_raises(RuntimeError) { server_mw.call(nil, payload, "q") { raise "boom" } }

    assert_equal [blob], payload["args"]
  end

  def test_client_middleware_only_applies_to_jobs_to_encrypt
    middleware = Robin::Encryption::ClientMiddleware

    assert_true middleware.applies?(nil, {"encrypt" => true}, "q", nil)
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q", nil)
  end

  def test_server_middleware_only_applies_to_encrypted_jobs
    middleware = Robin::Encryption::ServerMiddleware

    assert_true middleware.applies?(nil, {"encrypted" => 1}, "q")
    assert_false middleware.applies?(nil, {"jid" => "j"}, "q")
  end
end

# End-to-end checks; left out of mutant's selection (they need a server).
class EncryptionIntegrationTest < RobinTest
  def setup
    super
    config.encryption_keys = {1 => EncryptionTest::KEY1}
  end

  def test_args_are_encrypted_at_rest
    SecretJob.perform_async("4242424242424242", 100)
    raw = redis("LINDEX", "#{key_prefix_for_test}queue:default", 0)

    refute_includes raw, "4242"
    assert_equal 1, JSON.parse(raw)["encrypted"]
    assert_equal ["[encrypted]"], Robin::Queue.new.first.display_args
  end

  def test_retries_store_ciphertext_only
    config.heartbeat_interval = 0.2
    Robin.server!
    launcher = Robin::Launcher.new(config).run
    SecretJob.perform_async("4111111111111111", -1)

    assert_equal ["4111111111111111", -1], Timeout.timeout(5) { SecretJob::SEEN.pop }
    eventually { Robin::RetrySet.new.size == 1 }
    raw = redis("ZRANGE", "#{key_prefix_for_test}retry", 0, -1).first

    refute_includes raw, "4111"
    assert_includes raw, "declined"
  ensure
    launcher&.stop
  end
end
