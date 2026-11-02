# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/cron_assertions"

# Parsing, fields, zones and descriptions (fast unit tests for mutant).
class CronParseTest < Minitest::Test
  include CronAssertions

  cover "Robin::Cron*"

  def utc(*) = Time.utc(*)

  def cron(expr, tz: "UTC") = Robin::Cron.new(expr, tz: tz)

  def test_attributes
    c = cron("  5 4 3 2 1  ")

    assert_equal "5 4 3 2 1", c.expression
    assert_equal "5 4 3 2 1", c.to_s
    assert_equal "UTC", c.tz
    assert_equal [0], c.seconds
    assert_equal [5], c.minutes
    assert_equal [4], c.hours
    assert_equal [3], c.days
    assert_equal [2], c.months
    assert_equal [1], c.weekdays
    assert_instance_of Robin::Cron::Zone::Fixed, c.zone
    assert_equal '#<Robin::Cron "5 4 3 2 1" tz=UTC>', c.inspect
    assert_equal '#<Robin::Cron "5 4 3 2 1">', Robin::Cron.new("5 4 3 2 1").inspect
    assert_nil Robin::Cron.new(:"* * * * *").tz
    assert_equal "* * * * *", Robin::Cron.new(:"* * * * *").expression
  end

  def test_full_ranges
    c = cron("* * * * *")

    assert_equal (0..59).to_a, c.minutes
    assert_equal (0..23).to_a, c.hours
    assert_equal (1..31).to_a, c.days
    assert_equal (1..12).to_a, c.months
    assert_equal (0..6).to_a, c.weekdays
    assert_equal [0], c.seconds
    assert_equal (0..59).to_a, cron("* * * * * *").seconds
    assert_equal (1..31).to_a, cron("0 0 ? * ?").days
    assert_equal (0..6).to_a, cron("0 0 ? * ?").weekdays
  end

  def test_field_syntax
    assert_equal [0, 20, 40], cron("*/20 * * * *").minutes
    assert_equal [10, 20, 30, 40], cron("10-40/10 * * * *").minutes
    assert_equal [10, 13, 16, 19], cron("10-20/3 * * * *").minutes
    assert_equal [5, 20, 35, 50], cron("5/15 * * * *").minutes
    assert_equal [1, 2, 3, 7], cron("3,1-2,7,2 * * * *").minutes
    assert_equal [0, 59], cron("59,0 * * * *").minutes
    assert_equal [23], cron("0 23 * * *").hours
    assert_equal [1, 31], cron("0 0 31,1 * *").days
  end

  def test_names_and_sundays
    assert_equal [12], cron("0 0 1 dec *").months
    assert_equal [2, 3, 4], cron("0 0 1 Feb-apr *").months
    assert_equal [0, 6], cron("0 0 * * SAT,SUN").weekdays
    assert_equal [0, 1], cron("0 0 * * 0,7,1").weekdays
    assert_equal [5, 6], cron("0 0 * * 5-6/1").weekdays
    assert_equal [0, 5, 6], cron("0 0 * * 5-7").weekdays
    assert_equal [8], cron("0 08 * * *").hours # leading zero is decimal, not octal
    assert_equal [0, 7, 14, 21, 28, 35, 42, 49, 56], cron("*/7 * * * * *").seconds
  end

  def test_whitespace
    assert_equal [5], cron("5  4\t* *   * ").minutes
    assert_equal [4], cron("5  4\t* *   * ").hours
  end

  def test_parse_errors
    bad = ["1/2/3 * * * *", "1-2-3 * * * *", "1/2/x * * * *", "*/08 * * * *".sub("08", "0x8"), "", "* * * *", "* * * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * 32 * *",
      "* * * 0 *", "* * * 13 *", "* * * * 8", "*/0 * * * *", "*/-1 * * * *", "*/x * * * *",
      "5-1 * * * *", "* * * * FUNDAY", "a * * * *", "1.5 * * * *", "0x1 * * * *", "-1 * * * *",
      "1- * * * *", "* * * JANUARY *", "61 * * * * *"]

    bad.each do |expr|
      assert_raises(Robin::Cron::ParseError, expr) { cron(expr) }
    end
  end

  def test_parse_error_messages
    e = assert_raises(Robin::Cron::ParseError) { cron("* * *") }
    assert_equal 'cron expression must have 5 or 6 fields: "* * *"', e.message
    e = assert_raises(Robin::Cron::ParseError) { cron("*/0 * * * *") }
    assert_equal 'bad step in "*/0"', e.message
    e = assert_raises(Robin::Cron::ParseError) { cron("70 * * * *") }
    assert_equal '"70" is out of range 0-59', e.message
    e = assert_raises(Robin::Cron::ParseError) { cron("x * * * *") }
    assert_equal 'invalid cron value "x" in "x * * * *"', e.message
    assert_kind_of ArgumentError, e
  end

  def test_shortcuts
    {
      "@yearly" => "0 0 1 1 *", "@annually" => "0 0 1 1 *", "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0", "@daily" => "0 0 * * *", "@midnight" => "0 0 * * *", "@hourly" => "0 * * * *"
    }.each do |shortcut, expr|
      a = cron(shortcut)
      b = cron(expr)

      assert_equal shortcut, a.expression
      assert_equal [b.minutes, b.hours, b.days, b.months, b.weekdays], [a.minutes, a.hours, a.days, a.months, a.weekdays]
    end
    assert_equal [0], cron("@HOURLY").minutes
  end

  def test_last_day_of_month_field
    c = cron("0 0 L * *")

    assert_empty c.days
    assert_fires c, utc(2026, 4, 30)
    refute_fires c, utc(2026, 4, 29)
    assert_fires c, utc(2026, 12, 31)
    assert_fires c, utc(2028, 2, 29)
    refute_fires c, utc(2028, 2, 28)
    assert_fires c, utc(2027, 2, 28)
    assert_fires cron("0 0 l * *"), utc(2026, 1, 31)
  end

  def test_match_checks_every_field
    c = cron("30 15 10 * * 6")

    assert_fires c, utc(2026, 6, 6, 10, 15, 30) # a Saturday
    refute_fires c, utc(2026, 6, 6, 10, 15, 31)
    refute_fires c, utc(2026, 6, 6, 10, 16, 30)
    refute_fires c, utc(2026, 6, 6, 11, 15, 30)
    refute_fires c, utc(2026, 6, 7, 10, 15, 30)
    refute_fires cron("0 0 1 2 *"), utc(2026, 3, 1)
    assert_fires cron("0 0 1 2 *"), utc(2026, 2, 1)
    refute_fires cron("0 0 1 2 *"), utc(2026, 2, 1, 0, 0, 59) # five fields mean second 0
  end

  def test_day_matching_semantics
    both = cron("0 0 13 * 5")

    assert_fires both, utc(2026, 10, 13) # a Tuesday the 13th
    assert_fires both, utc(2026, 11, 6) # a Friday
    refute_fires both, utc(2026, 11, 7)
    dom_only = cron("0 0 13 * *")

    assert_fires dom_only, utc(2026, 11, 13)
    refute_fires dom_only, utc(2026, 11, 6)
    dow_only = cron("0 0 * * 5")

    assert_fires dow_only, utc(2026, 11, 6)
    refute_fires dow_only, utc(2026, 11, 13 + 1)
    assert_fires cron("0 0 ? * 5"), utc(2026, 11, 6)
    refute_fires cron("0 0 ? * 5"), utc(2026, 11, 7)
    assert_fires cron("0 0 13 * ?"), utc(2026, 11, 13)
    refute_fires cron("0 0 13 * ?"), utc(2026, 11, 12)
    assert_fires cron("0 0 * * *"), utc(2026, 11, 12)
  end

  def test_zone_selection
    assert_instance_of Robin::Cron::Zone::Local, Robin::Cron::Zone.for(nil)
    assert_instance_of Robin::Cron::Zone::Local, Robin::Cron::Zone.for("")
    %w[UTC Etc/UTC GMT Z].each do |name|
      zone = Robin::Cron::Zone.for(name)

      assert_instance_of Robin::Cron::Zone::Fixed, zone
      assert_equal "UTC", zone.label
      assert_equal utc(2026, 1, 1, 5), zone.to_wall(utc(2026, 1, 1, 5))
    end
    plus = Robin::Cron::Zone.for("+05:30")

    assert_equal "+05:30", plus.label
    assert_equal utc(2026, 1, 1, 5, 30), plus.to_wall(utc(2026, 1, 1))
    assert_equal utc(2026, 1, 1), plus.to_utc(utc(2026, 1, 1, 5, 30))
    minus = Robin::Cron::Zone.for("-0800")

    assert_equal "-0800", minus.label
    assert_equal utc(2025, 12, 31, 16), minus.to_wall(utc(2026, 1, 1))
    assert_equal "+00:00", Robin::Cron::Zone.for("+00:00").label
    assert_instance_of Robin::Cron::Zone::IANA, Robin::Cron::Zone.for("Europe/Berlin")
  end

  def test_offsets_are_decimal
    assert_equal utc(2026, 1, 1, 8, 9), Robin::Cron::Zone.for("+08:09").to_wall(utc(2026, 1, 1))
    assert_equal utc(2026, 1, 1, 10, 30), Robin::Cron::Zone.for("+10:30").to_wall(utc(2026, 1, 1))
  end

  def test_match_uses_the_zone
    c = cron("0 9 * * *", tz: "+05:30")

    assert_fires c, utc(2026, 1, 1, 3, 30)
    refute_fires c, utc(2026, 1, 1, 9)
  end

  def test_local_zone_with_half_hour_daylight_saving
    with_tz("Australia/Lord_Howe") do
      zone = Robin::Cron::Zone.for(nil)
      # 2026-10-04 02:00 -> 02:30: 02:15 doesn't exist
      assert_nil zone.to_utc(utc(2026, 10, 4, 2, 15))
      refute_nil zone.to_utc(utc(2026, 10, 4, 2, 45))
    end
  end

  def test_offset_forms
    assert_raises(Robin::Cron::ParseError) { Robin::Cron::Zone.for("+5:30") }
    assert_raises(Robin::Cron::ParseError) { Robin::Cron::Zone.for("x+05:30") }
    assert_raises(Robin::Cron::ParseError) { Robin::Cron::Zone.for("+05:30x") }
    assert_equal utc(2026, 1, 1, 1, 15), Robin::Cron::Zone.for("+0115").to_wall(utc(2026, 1, 1))
  end

  def test_fixed_zone_conversion
    zone = Robin::Cron::Zone.for("+01:00")
    time = Time.at(1_800_000_000, 500, :millisecond).getlocal("-07:00")
    wall = zone.to_wall(time)

    assert_predicate wall, :utc?
    assert_equal Time.at(1_800_003_600, 500, :millisecond).utc, wall
    assert_equal "-07:00", time.strftime("%:z") # the argument isn't modified
    assert_predicate zone.to_utc(wall), :utc?
    assert_equal time, zone.to_utc(wall)
  end

  def test_local_zone_round_trip
    zone = Robin::Cron::Zone.for(nil)
    instant = utc(2026, 7, 4, 12, 34, 56)
    local = instant.getlocal
    wall = zone.to_wall(instant)

    assert_nil zone.label
    assert_predicate wall, :utc?
    assert_equal [local.year, local.month, local.day, local.hour, local.min, local.sec],
      [wall.year, wall.month, wall.day, wall.hour, wall.min, wall.sec]
    assert_equal instant, zone.to_utc(wall)
    assert_predicate zone.to_utc(wall), :utc?
  end

  def test_local_zone_skipped_wall_times
    with_tz("America/New_York") do
      zone = Robin::Cron::Zone.for(nil)

      assert_nil zone.to_utc(utc(2026, 3, 8, 2, 30))
      assert_equal utc(2026, 3, 8, 7, 30), zone.to_utc(utc(2026, 3, 8, 3, 30))
      assert_equal utc(2026, 3, 8, 6, 59), zone.to_utc(utc(2026, 3, 8, 1, 59))
    end
  end

  def test_iana_zone
    zone = Robin::Cron::Zone.for("America/New_York")

    assert_equal "America/New_York", zone.label
    assert_equal utc(2026, 1, 1, 7, 8, 9), zone.to_wall(utc(2026, 1, 1, 12, 8, 9))
    local = utc(2026, 1, 1, 12, 8, 9).getlocal("+09:00")

    assert_equal utc(2026, 1, 1, 7, 8, 9), zone.to_wall(local)
    assert_equal "+09:00", local.strftime("%:z")
    assert_predicate zone.to_wall(local), :utc?
    assert_predicate zone.to_utc(utc(2026, 1, 1, 7)), :utc?
    assert_equal utc(2026, 1, 1, 12), zone.to_utc(utc(2026, 1, 1, 7))
    assert_nil zone.to_utc(utc(2026, 3, 8, 2, 30))
    # ambiguous 01:30 resolves to the first (daylight) occurrence
    assert_equal utc(2026, 11, 1, 5, 30), zone.to_utc(utc(2026, 11, 1, 1, 30))
    e = assert_raises(Robin::Cron::ParseError) { Robin::Cron::Zone.for("Mars/Olympus") }
    assert_equal 'unknown time zone "Mars/Olympus"', e.message
  end

  def test_iana_zone_without_tzinfo
    iana = Robin::Cron::Zone::IANA
    iana.define_singleton_method(:require) { |_| raise LoadError }
    e = assert_raises(Robin::Cron::ParseError) { iana.new("Europe/Paris") }
    assert_equal 'time zone "Europe/Paris" needs the tzinfo gem (add it to your Gemfile)', e.message
  ensure
    iana.singleton_class.remove_method(:require)
  end

  def test_descriptions
    {
      "* * * * *" => "every minute",
      "*/5 * * * *" => "every 5 minutes",
      "*/15 9-17 * * MON-FRI" => "every 15 minutes from 09:00 to 17:59 on weekdays",
      "7 * * * *" => "every hour at :07",
      "30 */2 * * *" => "every 2 hours at :30",
      "30 3 * * *" => "at 03:30",
      "0 0 * * 0,6" => "at 00:00 on weekends",
      "0 12 * * 1,3" => "at 12:00 on Monday, Wednesday",
      "0 12 L * *" => "at 12:00 on the last day of the month",
      "0 12 15 * *" => "at 12:00 on day 15 of the month",
      "0 12 1 1,7 *" => "at 12:00 on day 1 of the month in January, July",
      "0 12 ? * ?" => "at 12:00",
      "0 12 * ? *" => "at 12:00",
      "* * * * * *" => "every second",
      "*/10 * * * * *" => "every 10 seconds",
      "0 * * * * *" => "every minute",
      "1,2 * * * *" => "1,2 * * * *",
      "15 1-3 * * *" => "15 1-3 * * *",
      "*/5 1-3/2 * * *" => "*/5 1-3/2 * * *",
      "*/5 */2 * * *" => "*/5 */2 * * *",
      "5 1,2 * * *" => "5 1,2 * * *",
      "1-5/2 * * * * *" => "1-5/2 * * * * *",
      "* 5 * * *" => "every minute from 05:00 to 05:59",
      "0-59/5 * * * *" => "every 5 minutes",
      "*/5 2-4 * * *" => "every 5 minutes from 02:00 to 04:59",
      "*/5 2,4 * * *" => "*/5 2,4 * * *",
      "0 9 13 * 5" => "at 09:00 on day 13 of the month or on Friday",
      "0 9 L * 0,6" => "at 09:00 on the last day of the month or on weekends",
      "0 9 * 1-12 *" => "at 09:00",
      "0 9 1,15 6 *" => "at 09:00 on day 1, 15 of the month in June",
      "0 9 * 6 1-5" => "at 09:00 on weekdays in June",
      "0 9 * 6 MON-SAT" => "at 09:00 on Monday, Tuesday, Wednesday, Thursday, Friday, Saturday in June",
      "0 9 * 1-11 *" => "at 09:00 in January, February, March, April, May, June, July, August, September, October, November",
      "0 9 * * 0-6" => "at 09:00 on Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday",
      "0 9 * * 1-7" => "at 09:00 on Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday",
      "0 0 * * 7" => "at 00:00 on Sunday",
      "5 * * * * *" => "5 * * * * *",
      "*/2 * * * * *" => "every 2 seconds",
      "*/20 * * * * *" => "every 20 seconds",
      "1-59/2 * * * *" => "1-59/2 * * * *",
      "0 0-23/2 * * *" => "every 2 hours at :00",
      "0 1-23/2 * * *" => "0 1-23/2 * * *",
      "1,2 5 * * *" => "1,2 5 * * *",
      "*/59 * * * * *" => "every 59 seconds"
    }.each do |expr, text|
      label = (text == expr) ? text : "#{text} (UTC)"

      assert_equal label, cron(expr).description, expr
    end
    assert_equal "every minute (+05:30)", cron("* * * * *", tz: "+05:30").description
    assert_equal "every minute (America/New_York)", cron("* * * * *", tz: "America/New_York").description
    assert_equal "every minute", Robin::Cron.new("* * * * *").description
    assert_equal "at 00:00 (UTC)", cron("@daily").description
  end

  private

  def with_tz(zone)
    previous = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    ENV["TZ"] = previous
  end
end
