# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/cron_assertions"

# next_time / previous_time search (fast unit tests for mutant).
class CronSearchTest < Minitest::Test
  include CronAssertions

  cover "Robin::Cron*"

  def utc(*) = Time.utc(*)

  def cron(expr, tz: "UTC") = Robin::Cron.new(expr, tz: tz)

  # Brute force reference: the first candidate strictly after +from+, then
  # every +step+ seconds (60 when the seconds field is just 0).
  def brute_next(c, from, step:, limit:)
    t = Time.at(from.to_i - (from.to_i % step)).utc + step
    limit.times do
      return t if c.match?(t)

      t += step
    end
    nil
  end

  def test_next_time_matches_brute_force
    exprs = ["*/7 */5 * * *", "0 12 1,15 * 5", "*/20 1-2 * * *", "1-5/2 3 * * * *", "30 4 * * SUN"]
    starts = [utc(2026, 1, 1), utc(2026, 2, 28, 23, 59, 59), utc(2026, 12, 31, 23, 58, 30), utc(2027, 3, 15, 10, 15, 0, 500_000)]
    exprs.each do |expr|
      c = cron(expr)
      starts.each do |from|
        expected = c.next_time(from)

        assert_operator expected, :>, from, "#{expr} from #{from}"
        assert_fires c, expected, "#{expr} from #{from} gave non-matching #{expected}"
        step = (c.seconds == [0]) ? 60 : 1
        reference = brute_next(c, from, step: step, limit: ((expected - from) / step).ceil + 2)

        assert_equal reference, expected, "#{expr} from #{from}"
      end
    end
  end

  def brute_previous(c, from, limit:)
    t = Time.at(from.to_i).utc
    t -= 1 if t == from
    limit.times do
      return t if c.match?(t)

      t -= 1
    end
    nil
  end

  SECOND_EXPRESSIONS = ["59 59 * * * *", "0,59 * * * * *", "*/13 58,59 1,23 * * *", "30 */20 * * * *",
    "58-59 0 0 * * *", "* * * * * *", "1 1 1 * * *"].freeze

  def test_second_granularity_matches_brute_force_both_ways
    starts = [utc(2026, 1, 1), utc(2026, 1, 1, 0, 0, 0, 250_000), utc(2026, 1, 1, 23, 59, 59),
      utc(2026, 1, 1, 1, 0, 30), utc(2026, 6, 30, 23, 59, 58)]
    SECOND_EXPRESSIONS.each do |expr|
      c = cron(expr)
      starts.each do |from|
        n = c.next_time(from)
        p = c.previous_time(from)

        assert_equal brute_next(c, from, step: 1, limit: (n - from).ceil + 2), n, "next #{expr} from #{from.inspect}"
        assert_equal brute_previous(c, from, limit: (from - p).ceil + 2), p, "previous #{expr} from #{from.inspect}"
      end
    end
  end

  def test_previous_time_is_the_inverse_of_next_time
    exprs = ["*/7 */5 * * *", "59 23 31 12 *", "0 0 29 2 *", "15 10 * 3,5 1", "0 12 1,15 * 5", "*/20 1-2 * * *",
      "0 0 L 2 *", "1-5/2 3 * * * *", "30 4 * * SUN", "* * * * *", "0 0 1 1 *"]
    starts = [utc(2026, 1, 1), utc(2026, 3, 1), utc(2026, 12, 31, 23, 58, 30), utc(2027, 3, 15, 10, 15, 0, 500_000)]
    exprs.each do |expr|
      c = cron(expr)
      starts.each do |from|
        prev = c.previous_time(from)

        assert_operator prev, :<, from, "#{expr} before #{from}"
        assert_fires c, prev, "#{expr} before #{from} gave non-matching #{prev}"
        assert_operator c.next_time(prev), :>=, from, "#{expr}: nothing may match between #{prev} and #{from}"
      end
    end
  end

  def test_sparse_expressions
    assert_equal utc(2026, 12, 31, 23, 59), cron("59 23 31 12 *").next_time(utc(2026, 1, 1))
    assert_equal utc(2027, 2, 28), cron("0 0 L 2 *").next_time(utc(2026, 3, 1))
    assert_equal utc(2026, 3, 2, 10, 15), cron("15 10 * 3,5 1").next_time(utc(2026, 1, 1))
    assert_equal utc(2026, 5, 4, 10, 15), cron("15 10 * 3,5 1").next_time(utc(2026, 3, 30, 10, 15))
  end

  def test_exact_boundaries
    c = cron("0 0 * * *")

    assert_equal utc(2026, 1, 2), c.next_time(utc(2026, 1, 1))
    assert_equal utc(2026, 1, 1), c.next_time(utc(2025, 12, 31, 23, 59, 59))
    assert_equal utc(2025, 12, 31), c.previous_time(utc(2026, 1, 1))
    assert_equal utc(2026, 1, 1), c.previous_time(utc(2026, 1, 1, 0, 0, 0, 1))
    assert_equal utc(2026, 1, 1), c.previous_time(utc(2026, 1, 1, 0, 0, 1))
  end

  def test_month_rollover_and_year_wrap
    assert_equal utc(2027, 1, 1), cron("0 0 1 1 *").next_time(utc(2026, 1, 1))
    assert_equal utc(2026, 1, 1), cron("0 0 1 1 *").previous_time(utc(2026, 12, 31))
    assert_equal utc(2026, 12, 1), cron("0 0 1 12 *").next_time(utc(2026, 11, 2))
    assert_equal utc(2025, 12, 1), cron("0 0 1 12 *").previous_time(utc(2026, 11, 2))
    assert_equal utc(2026, 11, 30, 23, 59), cron("59 23 * 11 *").previous_time(utc(2026, 12, 15))
  end

  def test_hour_minute_second_rollover
    assert_equal utc(2026, 1, 2, 1), cron("0 1 * * *").next_time(utc(2026, 1, 1, 2))
    assert_equal utc(2026, 1, 1, 1), cron("0 1 * * *").previous_time(utc(2026, 1, 1, 2))
    assert_equal utc(2025, 12, 31, 3), cron("0 3 * * *").previous_time(utc(2026, 1, 1, 2))
    assert_equal utc(2026, 1, 1, 3, 10), cron("10 * * * *").next_time(utc(2026, 1, 1, 2, 30))
    assert_equal utc(2026, 1, 1, 2, 10), cron("10 * * * *").previous_time(utc(2026, 1, 1, 2, 30))
    assert_equal utc(2026, 1, 1, 1, 50), cron("50 * * * *").previous_time(utc(2026, 1, 1, 2, 30))
    assert_equal utc(2026, 1, 1, 2, 31, 5), cron("5 * * * * *").next_time(utc(2026, 1, 1, 2, 30, 30))
    assert_equal utc(2026, 1, 1, 2, 30, 5), cron("5 * * * * *").previous_time(utc(2026, 1, 1, 2, 30, 30))
    assert_equal utc(2026, 1, 1, 2, 29, 45), cron("45 * * * * *").previous_time(utc(2026, 1, 1, 2, 30, 30))
    assert_equal utc(2026, 1, 1, 2, 30, 45), cron("45 * * * * *").next_time(utc(2026, 1, 1, 2, 30, 30))
  end

  def test_impossible_expressions_return_nil
    assert_nil cron("0 0 30 2 *").next_time(utc(2026, 1, 1))
    assert_nil cron("0 0 30 2 *").previous_time(utc(2026, 1, 1))
    assert_nil cron("0 0 31 4,6,9,11 *").next_time(utc(2026, 1, 1))
  end

  def test_previous_time_lands_on_the_last_second_of_each_unit
    assert_equal utc(2026, 1, 31, 23, 59, 59), cron("59 59 23 * 1 *").previous_time(utc(2026, 2, 15))
    assert_equal utc(2026, 10, 12, 23, 59, 59), cron("59 59 23 * * 1").previous_time(utc(2026, 10, 14, 12))
    assert_equal utc(2026, 10, 13, 5, 59, 59), cron("59 59 5 * * *").previous_time(utc(2026, 10, 14, 3))
    assert_equal utc(2026, 10, 13, 23, 59, 59), cron("59 59 23 * * *").previous_time(utc(2026, 10, 14, 3))
    assert_equal utc(2026, 10, 14, 5, 59, 59), cron("59 59 5 * * *").previous_time(utc(2026, 10, 14, 8))
    assert_equal utc(2026, 10, 14, 9, 59, 59), cron("59 59 * * * *").previous_time(utc(2026, 10, 14, 10, 30))
    assert_equal utc(2026, 10, 14, 10, 10, 59), cron("59 10 * * * *").previous_time(utc(2026, 10, 14, 10, 30))
    assert_equal utc(2026, 10, 14, 10, 29, 59), cron("59 * * * * *").previous_time(utc(2026, 10, 14, 10, 30, 30))
  end

  def test_previous_time_uses_the_zone
    assert_equal utc(2026, 1, 1, 3, 30), cron("0 9 * * *", tz: "+05:30").previous_time(utc(2026, 1, 1, 4))
  end

  def test_rare_dates_within_horizon
    # Feb 29 on a Monday (dom-or-dow semantics make this "29th of Feb or any Monday in Feb")
    assert_equal utc(2027, 2, 1), cron("0 0 29 2 1").next_time(utc(2026, 3, 1))
    assert_equal utc(2032, 2, 29), cron("0 0 29 2 *").next_time(utc(2028, 3, 1))
    assert_equal utc(2024, 2, 29), cron("0 0 29 2 *").previous_time(utc(2028, 2, 28))
  end

  def test_search_does_not_modify_its_argument
    from = Time.utc(2026, 5, 5, 12).getlocal("+09:00")
    cron("0 * * * *").next_time(from)
    cron("0 * * * *").previous_time(from)
    cron("0 * * * *", tz: "America/New_York").next_time(from)

    refute_predicate from, :utc?
    assert_equal "+09:00", from.strftime("%:z")
  end

  def test_defaults_to_now
    c = cron("* * * * * *")
    before = Time.now

    assert_operator c.next_time, :>, before
    assert_operator c.previous_time, :<=, Time.now
    assert_predicate c.next_time, :utc?
    assert_predicate c.previous_time, :utc?
  end

  def test_results_are_utc_for_local_input
    from = Time.utc(2026, 5, 5, 12).getlocal("+09:00")

    assert_equal utc(2026, 5, 5, 13), cron("0 * * * *").next_time(from)
    assert_predicate cron("0 * * * *").next_time(from), :utc?
    assert_equal utc(2026, 5, 5, 11), cron("0 * * * *").previous_time(from)
  end

  def test_zone_aware_search
    ny = "America/New_York"

    assert_equal utc(2026, 3, 9, 6, 30), cron("30 2 * * *", tz: ny).next_time(utc(2026, 3, 8, 5))
    assert_equal utc(2026, 3, 7, 7, 30), cron("30 2 * * *", tz: ny).previous_time(utc(2026, 3, 9, 6))
    assert_equal utc(2026, 1, 1, 3, 30), cron("0 9 * * *", tz: "+05:30").next_time(utc(2026, 1, 1))
    assert_equal utc(2025, 12, 31, 3, 30), cron("0 9 * * *", tz: "+05:30").previous_time(utc(2026, 1, 1))
    # 01:30 happens twice on 2026-11-01 in New York; the search never returns the second one.
    c = cron("30 1 * * *", tz: ny)

    assert_equal utc(2026, 11, 1, 5, 30), c.next_time(utc(2026, 11, 1, 4))
    assert_equal utc(2026, 11, 2, 6, 30), c.next_time(utc(2026, 11, 1, 5, 30))
    assert_equal utc(2026, 11, 1, 5, 30), c.previous_time(utc(2026, 11, 2, 6, 30))
  end
end
