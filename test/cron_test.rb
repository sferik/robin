# frozen_string_literal: true

require_relative "test_helper"

class CronTest < Minitest::Test
  cover "Robin::Cron*"

  def utc(*a) = Time.utc(*a)

  def cron(expr, tz: "UTC") = Robin::Cron.new(expr, tz: tz)

  def test_every_minute
    assert_equal utc(2026, 1, 1, 0, 1), cron("* * * * *").next_time(utc(2026, 1, 1, 0, 0, 30))
    assert_equal utc(2026, 1, 1, 0, 1), cron("* * * * *").next_time(utc(2026, 1, 1, 0, 0))
    assert_equal utc(2026, 1, 1, 0, 0), cron("* * * * *").previous_time(utc(2026, 1, 1, 0, 0, 30))
    assert_equal utc(2025, 12, 31, 23, 59), cron("* * * * *").previous_time(utc(2026, 1, 1))
  end

  def test_steps_ranges_lists_names
    c = cron("*/15 9-17 * * MON-FRI")

    assert_equal utc(2026, 10, 19, 9, 0), c.next_time(utc(2026, 10, 17, 12)) # Sat -> Mon
    assert_equal utc(2026, 10, 16, 17, 45), c.previous_time(utc(2026, 10, 17, 12))
    assert_equal [5, 20, 35, 50], cron("5/15 * * * *").minutes
    assert_equal [1, 3, 5], cron("0 0 * * 1,3,5").weekdays
    assert_equal [0], cron("0 0 * * 7").weekdays
    assert_equal [1, 7], cron("0 0 1 jan,JUL *").months
  end

  def test_dom_dow_or_semantics
    c = cron("0 0 13 * FRI")

    assert_equal utc(2026, 10, 16), c.next_time(utc(2026, 10, 14)) # Friday the 16th
    assert_equal utc(2026, 11, 13), c.next_time(utc(2026, 11, 7)) # the 13th (a Friday anyway)
    assert_equal utc(2026, 11, 13), cron("0 0 13 * *").next_time(utc(2026, 10, 14))
  end

  def test_last_day_of_month_and_leap_years
    assert_equal utc(2028, 2, 29), cron("0 0 L * *").next_time(utc(2028, 2, 1))
    assert_equal utc(2027, 2, 28), cron("0 0 L * *").next_time(utc(2027, 2, 1))
    assert_equal utc(2032, 2, 29), cron("0 0 29 2 *").next_time(utc(2028, 3, 1))
  end

  def test_shortcuts_and_seconds
    assert_equal utc(2027, 1, 1), cron("@yearly").next_time(utc(2026, 5, 5))
    assert_equal utc(2026, 5, 5, 1), cron("@hourly").next_time(utc(2026, 5, 5, 0, 30))
    assert_equal utc(2026, 5, 10), cron("@weekly").next_time(utc(2026, 5, 5)) # Sunday
    assert_equal utc(2026, 1, 1, 0, 0, 10), cron("*/10 * * * * *").next_time(utc(2026, 1, 1, 0, 0, 5))
    assert_equal utc(2026, 1, 1, 0, 0, 0), cron("*/10 * * * * *").previous_time(utc(2026, 1, 1, 0, 0, 5))
  end

  def test_fixed_offset
    c = cron("0 9 * * *", tz: "+05:30")

    assert_equal utc(2026, 1, 1, 3, 30), c.next_time(utc(2026, 1, 1))
  end

  def test_dst_with_tzinfo
    ny = "America/New_York"
    # 2026-03-08 02:30 doesn't exist in New York: skipped.
    assert_equal utc(2026, 3, 9, 6, 30), cron("30 2 * * *", tz: ny).next_time(utc(2026, 3, 8, 5))
    # Daily 09:00 shifts in UTC across the change.
    assert_equal utc(2026, 3, 7, 14), cron("0 9 * * *", tz: ny).next_time(utc(2026, 3, 7))
    assert_equal utc(2026, 3, 8, 13), cron("0 9 * * *", tz: ny).next_time(utc(2026, 3, 8))
    # 2026-11-01 01:30 happens twice; runs once (the first).
    c = cron("30 1 * * *", tz: ny)
    first = c.next_time(utc(2026, 11, 1, 4))

    assert_equal utc(2026, 11, 1, 5, 30), first
    assert_equal utc(2026, 11, 2, 6, 30), c.next_time(first)
  end

  def test_errors
    assert_raises(Robin::Cron::ParseError) { cron("* * *") }
    assert_raises(Robin::Cron::ParseError) { cron("60 * * * *") }
    assert_raises(Robin::Cron::ParseError) { cron("*/0 * * * *") }
    assert_raises(Robin::Cron::ParseError) { cron("* * * * FUNDAY") }
    assert_raises(Robin::Cron::ParseError) { Robin::Cron.new("* * * * *", tz: "Mars/Olympus") }
  end

  def test_match_and_description
    on_the_fifth = cron("*/5 * * * *").match?(utc(2026, 1, 1, 0, 10))
    off_the_fifth = cron("*/5 * * * *").match?(utc(2026, 1, 1, 0, 11))

    assert on_the_fifth
    refute off_the_fifth
    assert_equal "every 5 minutes (UTC)", cron("*/5 * * * *").description
    assert_equal "at 03:30 on weekdays (UTC)", cron("30 3 * * 1-5").description
    assert_equal "every minute (UTC)", cron("* * * * *").description
  end
end
