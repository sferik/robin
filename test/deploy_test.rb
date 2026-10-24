# frozen_string_literal: true

require_relative "test_helper"

class DeployTest < RobinTest
  cover "Robin::Deploy*"

  T0 = Time.at(1_800_000_000, 250, :millisecond)

  def stored = redis("ZRANGE", config.key("deploys"), 0, -1, "WITHSCORES").each_slice(2).map { |m, s| [JSON.parse(m), s.to_i] }

  def test_mark_records_the_time_and_label
    assert_true Robin::Deploy.mark!("v1", at: T0, config: config)
    assert_equal [[{"at" => 1_800_000_000_250, "label" => "v1"}, 1_800_000_000_250]], stored
  end

  def test_defaults
    before = Robin.now_ms

    assert Robin::Deploy.mark!
    after = Robin.now_ms
    (entry, score), = stored

    assert_nil entry["label"]
    assert_equal score, entry["at"]
    assert_operator score, :>=, before
    assert_operator score, :<=, after
  end

  def test_a_label_is_marked_once_an_hour
    assert assert_roundtrips(1) { Robin::Deploy.mark!("v1", at: T0, config: config) }
    assert_false assert_roundtrips(1) { Robin::Deploy.mark!("v1", at: T0 + 60, config: config) }
    assert Robin::Deploy.mark!("v2", at: T0 + 60, config: config)
    assert Robin::Deploy.mark!(at: T0 + 120, config: config)
    assert Robin::Deploy.mark!(at: T0 + 180, config: config)

    assert_equal ["v1", "v2", nil, nil], stored.map { |(entry, _)| entry["label"] }
    dedup = config.key("deploy", Digest::SHA256.hexdigest("v1"))

    assert_includes 3599..3600, redis("TTL", dedup)
    assert_equal "1800000000250", redis("GET", dedup)
  end

  def test_labels_are_strings_cut_to_200_characters
    Robin::Deploy.mark!(42, at: T0, config: config)
    Robin::Deploy.mark!("x" * 300, at: T0, config: config)

    assert_equal ["42", "x" * 200], stored.map { |(entry, _)| entry["label"] }
    refute Robin::Deploy.mark!("x" * 201, at: T0, config: config)
  end

  def test_markers_older_than_metrics_retention_are_trimmed
    config.metrics_retention_days = 2
    old = T0 - (2 * 86_400)
    redis("ZADD", config.key("deploys"), -5, JSON.generate({"label" => "ancient"}))
    Robin::Deploy.mark!("old", at: old - Rational(1, 1000), config: config)
    Robin::Deploy.mark!("edge", at: old, config: config)
    Robin::Deploy.mark!("new", at: T0, config: config)

    assert_equal %w[edge new], stored.map { |(entry, _)| entry["label"] }
  end

  def test_list
    Robin::Deploy.mark!("a", at: T0, config: config)
    Robin::Deploy.mark!("b", at: T0 + 10, config: config)
    Robin::Deploy.mark!("c", at: T0 + 20, config: config)

    assert_equal %w[a b], Robin::Deploy.list(from: T0, to: T0 + 10, config: config).map { |d| d["label"] }
    assert_equal [{"at" => 1_800_000_020_250, "label" => "c"}], Robin::Deploy.list(from: T0 + Rational(10_001, 1000), to: T0 + 20, config: config)
    assert_empty Robin::Deploy.list(from: T0 - 10, to: T0 - Rational(1, 1000), config: config)
  end

  def test_list_defaults
    Robin::Deploy.mark!("now")

    assert_equal ["now"], Robin::Deploy.list(from: Time.now - 60).map { |d| d["label"] }
    Robin::Deploy.mark!("later", at: Time.now + 60)

    assert_equal ["now"], Robin::Deploy.list(from: Time.now - 60).map { |d| d["label"] }
  end
end
