# frozen_string_literal: true

require_relative "test_helper"

class ProgressTest < RobinTest
  cover "Robin::Progress*"

  def test_report_stores_clamped_rounded_percent
    data = assert_roundtrips(1) { Robin::Progress.report("j1", 42.456, "rows", {"done" => 3}, config: config) }

    assert_in_delta 42.5, data["pct"]
    assert_equal "rows", data["msg"]
    assert_equal({"done" => 3}, data["meta"])
    assert_in_delta Robin.now_ms, data["at"], 1_000
    assert_equal data, Robin::Progress.fetch("j1", config: config)
    ttl = redis("TTL", config.key("progress", "j1"))

    assert_operator ttl, :>, Robin::Progress::TTL - 5
    assert_operator ttl, :<=, Robin::Progress::TTL
  end

  def test_report_clamps_and_omits_empty_meta
    assert_in_delta 100.0, Robin::Progress.report("j2", 250, config: config)["pct"]
    data = Robin::Progress.report("j2", -3, config: config)

    assert_in_delta 0.0, data["pct"]
    assert_nil data["msg"]
    refute data.key?("meta")
    assert_equal ["at", "msg", "pct"], Robin::Progress.fetch("j2", config: config).keys.sort
  end

  def test_an_unknown_percent_is_stored_as_nil
    data = Robin::Progress.report("j4", nil, "1,200 rows", config: config)

    assert_nil data["pct"]
    assert_equal({"pct" => nil, "msg" => "1,200 rows", "at" => data["at"]}, Robin::Progress.fetch("j4", config: config))
  end

  def test_report_defaults_to_global_config
    Robin::Progress.report("j3", "7")

    assert_in_delta 7.0, Robin::Progress.fetch("j3")["pct"]
  end

  def test_entry_and_set_command
    data = Robin::Progress.entry(55)

    assert_equal %w[at msg pct], data.keys.sort
    assert_in_delta 55.0, data["pct"]
    assert_nil data["msg"]
    assert_in_delta Robin.now_ms, data["at"], 1_000
    assert_equal({"pct" => 7.5, "msg" => "m", "at" => data["at"], "meta" => {"k" => 1}},
      Robin::Progress.entry(7.5, "m", {"k" => 1}).merge("at" => data["at"]))
    assert_equal ["SET", config.key("progress", "j9"), '{"pct":1.0}', "EX", Robin::Progress::TTL],
      Robin::Progress.set_command(config, "j9", {"pct" => 1.0})
  end

  def test_fetch_missing
    assert_nil Robin::Progress.fetch("nope", config: config)
  end

  def test_fetch_many
    Robin::Progress.report("a", 10, config: config)
    Robin::Progress.report("c", 30, config: config)

    result = assert_roundtrips(1) { Robin::Progress.fetch_many(%w[a b c], config: config) }

    assert_equal %w[a c], result.keys
    assert_in_delta 10.0, result["a"]["pct"]
    assert_in_delta 30.0, result["c"]["pct"]
    assert_empty assert_roundtrips(0) { Robin::Progress.fetch_many([], config: config) }
    assert_equal ["a"], Robin::Progress.fetch_many(["a"]).keys
  end
end
