# frozen_string_literal: true

require "date"

module Robin
  # A cron expression.
  #
  #   cron = Robin::Cron.new("*/15 9-17 * * MON-FRI", tz: "America/New_York")
  #   cron.next_time               # => next matching Time (UTC)
  #   cron.previous_time
  #   cron.description             # => "every 15 minutes from 09:00 to 17:59 on weekdays (America/New_York)"
  #
  # Five fields (minute hour day-of-month month day-of-week), or six with a
  # leading seconds field. Supports *, lists (1,2), ranges (1-5), steps
  # (*/5, 10-40/10, 5/15), month and weekday names, ? (same as *), L in the
  # day-of-month field (last day of the month), 7 as Sunday, and the
  # @yearly, @annually, @monthly, @weekly, @daily, @midnight and @hourly
  # shortcuts. When both day fields are restricted, a day matches if
  # either does.
  #
  # Time zones: nil (the system zone), "UTC", fixed offsets ("+05:30"), or
  # IANA names ("Europe/Berlin", needs the tzinfo gem). Wall-clock times
  # skipped by a daylight-saving change don't run; repeated ones run once.
  class Cron
    class ParseError < ArgumentError; end

    SHORTCUTS = {
      "@yearly" => "0 0 1 1 *", "@annually" => "0 0 1 1 *", "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0", "@daily" => "0 0 * * *", "@midnight" => "0 0 * * *", "@hourly" => "0 * * * *"
    }.freeze
    MONTHS = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC].each_with_index.to_h { |m, i| [m, i + 1] }.freeze
    DAYS = %w[SUN MON TUE WED THU FRI SAT].each_with_index.to_h.freeze
    DAY_NAMES = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze
    MONTH_NAMES = %w[January February March April May June July August September October November December].freeze
    ANY = %w[* ?].freeze

    # Upper bound on search steps. Every step moves to the next candidate
    # month, day, hour, minute or second, so this spans decades even for
    # the sparsest expressions; impossible ones (Feb 30) give up with nil.
    MAX_STEPS = 20_000

    attr_reader :expression, :tz, :zone, :seconds, :minutes, :hours, :days, :months, :weekdays

    def initialize(expression, tz: nil)
      @expression = expression.to_s.strip
      @tz = tz
      @zone = Zone.for(tz)
      parse(SHORTCUTS.fetch(@expression.downcase, @expression))
    end

    def to_s = @expression

    def inspect = "#<Robin::Cron #{@expression.inspect}#{" tz=#{@tz}" if @tz}>"

    # Whether +time+ (to the second) matches.
    def match?(time)
      w = @zone.to_wall(time)
      @months.include?(w.month) && day_match?(w) && @hours.include?(w.hour) &&
        @minutes.include?(w.min) && @seconds.include?(w.sec)
    end

    # The first matching time strictly after +from+, in UTC.
    def next_time(from = Time.now)
      w = @zone.to_wall(from)
      MAX_STEPS.times do
        if !@months.include?(w.month)
          w = next_month(w)
        elsif !day_match?(w)
          w = next_day(w)
        elsif !(h = @hours.find { |x| x >= w.hour })
          w = next_day(w)
        elsif h > w.hour
          w = Time.utc(w.year, w.month, w.day, h)
        elsif !(m = @minutes.find { |x| x >= w.min })
          w = Time.utc(w.year, w.month, w.day, w.hour) + 3_600
        elsif m > w.min
          w = Time.utc(w.year, w.month, w.day, w.hour, m)
        elsif !(s = @seconds.find { |x| x >= w.sec })
          w = Time.utc(w.year, w.month, w.day, w.hour, w.min) + 60
        else
          w = Time.utc(w.year, w.month, w.day, w.hour, w.min, s)
          utc = @zone.to_utc(w)
          return utc if utc && utc > from

          w += 1
        end
      end
      nil
    end

    # The last matching time strictly before +from+, in UTC.
    def previous_time(from = Time.now)
      w = @zone.to_wall(from)
      MAX_STEPS.times do
        if !@months.include?(w.month)
          w = Time.utc(w.year, w.month) - 1
        elsif !day_match?(w)
          w = Time.utc(w.year, w.month, w.day) - 1
        elsif !(h = @hours.reverse_each.find { |x| x <= w.hour })
          w = Time.utc(w.year, w.month, w.day) - 1
        elsif h < w.hour
          w = Time.utc(w.year, w.month, w.day, h, 59, 59)
        elsif !(m = @minutes.reverse_each.find { |x| x <= w.min })
          w = Time.utc(w.year, w.month, w.day, w.hour) - 1
        elsif m < w.min
          w = Time.utc(w.year, w.month, w.day, w.hour, m, 59)
        elsif !(s = @seconds.reverse_each.find { |x| x <= w.sec })
          w = Time.utc(w.year, w.month, w.day, w.hour, w.min) - 1
        else
          w = Time.utc(w.year, w.month, w.day, w.hour, w.min, s)
          utc = @zone.to_utc(w)
          return utc if utc && utc < from

          w -= 1
        end
      end
      nil
    end

    # Best-effort English description, e.g. "every 5 minutes" or
    # "at 03:30 on Monday". Falls back to the expression itself.
    def description
      text = describe_time
      return @expression unless text

      parts = [text, describe_days, describe_months].compact
      label = @zone.label
      parts << "(#{label})" if label
      parts.join(" ")
    end

    private

    def next_month(w) = (w.month == 12) ? Time.utc(w.year + 1) : Time.utc(w.year, w.month + 1)

    def next_day(w) = Time.utc(w.year, w.month, w.day) + 86_400

    def describe_time
      minute_step = step_of(@minutes, 59)
      hour_step = step_of(@hours, 23)
      second_step = step_of(@seconds, 59)
      if !@seconds.eql?([0])
        every(second_step, "second") if second_step
      elsif minute_step && hour_step == 1
        every(minute_step, "minute")
      elsif minute_step && contiguous?(@hours)
        format("%s from %02d:00 to %02d:59", every(minute_step, "minute"), @hours.first, @hours.last)
      elsif @minutes.one? && hour_step
        format("%s at :%02d", every(hour_step, "hour"), @minutes.first)
      elsif @minutes.one? && @hours.one?
        format("at %02d:%02d", @hours.first, @minutes.first)
      end
    end

    # 1 for every value, n for "*/n", nil for anything else.
    def step_of(values, max) = (1..max).find { |n| values == 0.step(max, n).to_a }

    def contiguous?(values) = values == (values.first..values.last).to_a

    def every(step, unit) = (step == 1) ? "every #{unit}" : "every #{step} #{unit}s"

    def describe_days
      days = [describe_dom, describe_dow].compact
      days.join(" or ") unless days.empty?
    end

    def describe_dom
      return "on the last day of the month" if @last_dom

      "on day #{@days.join(", ")} of the month" unless @dom_any
    end

    def describe_dow
      return if @dow_any

      case @weekdays
      when [1, 2, 3, 4, 5] then "on weekdays"
      when [0, 6] then "on weekends"
      else "on #{@weekdays.map { |d| DAY_NAMES.fetch(d) }.join(", ")}"
      end
    end

    def describe_months
      "in #{@months.map { |m| MONTH_NAMES.fetch(m - 1) }.join(", ")}" if @months.size < 12
    end

    def parse(expr)
      parts = expr.split
      parts.unshift("0") if parts.size == 5
      raise ParseError, "cron expression must have 5 or 6 fields: #{@expression.inspect}" unless parts.size == 6

      sec, min, hour, dom, month, dow = parts #: [String, String, String, String, String, String]
      @seconds = field(sec, 0, 59)
      @minutes = field(min, 0, 59)
      @hours = field(hour, 0, 23)
      @last_dom = dom.casecmp?("L")
      @days = @last_dom ? [] : field(dom, 1, 31)
      @months = field(month, 1, 12, MONTHS)
      weekdays = field(dow, 0, 7, DAYS)
      @weekdays = weekdays.include?(7) ? ((weekdays - [7]) | [0]).sort : weekdays
      @dom_any = ANY.include?(dom)
      @dow_any = ANY.include?(dow)
    end

    def field(text, min, max, names = {})
      values = text.split(",").flat_map do |part|
        range, step = part.split("/", 2) #: [String, String] | [String]
        step = step ? Integer(step, 10, exception: false) : 1
        raise ParseError, "bad step in #{part.inspect}" unless step&.positive?

        first, last =
          if ANY.include?(range)
            [min, max]
          elsif range.include?("-")
            range.split("-", 2).map { |v| value(v, names) }
          else
            v = value(range, names)
            [v, part.include?("/") ? max : v]
          end #: [Integer, Integer]
        raise ParseError, "#{part.inspect} is out of range #{min}-#{max}" if first < min || last > max || first > last

        first.step(last, step).to_a #: Array[Integer]
      end
      values.uniq.sort
    end

    def value(text, names)
      names.fetch(text.upcase) { Integer(text, 10) }
    rescue ArgumentError
      raise ParseError, "invalid cron value #{text.inspect} in #{@expression.inspect}"
    end

    def day_match?(w)
      dom = @last_dom ? Date.new(w.year, w.month, -1).day == w.day : @days.include?(w.day)
      dow = @weekdays.include?(w.wday)
      if @dom_any then dow
      elsif @dow_any then dom
      else dom || dow
      end
    end

    # Converts between UTC instants and "wall clock" times, represented as
    # UTC Time objects holding the local fields.
    module Zone
      OFFSET = /\A(?<sign>[+-])(?<hours>\d{2}):?(?<minutes>\d{2})\z/

      def self.for(tz)
        case tz
        when nil, "" then Local.new
        when "UTC", "Etc/UTC", "GMT", "Z" then Fixed.new(0, "UTC")
        when OFFSET
          m = Regexp.last_match #: MatchData
          seconds = Integer(m[:hours], 10) * 3600 + Integer(m[:minutes], 10) * 60
          Fixed.new((m[:sign] == "-") ? -seconds : seconds, tz)
        else IANA.new(tz)
        end
      end

      class Fixed
        attr_reader :label

        def initialize(offset, label)
          @offset = offset
          @label = label
        end

        def to_wall(time) = (time + @offset).utc

        def to_utc(wall) = wall - @offset
      end

      class Local
        attr_reader :label

        def to_wall(time)
          t = time.getlocal
          Time.utc(t.year, t.month, t.day, t.hour, t.min, t.sec)
        end

        # nil for wall times skipped by a daylight-saving change.
        def to_utc(wall)
          t = Time.local(wall.year, wall.month, wall.day, wall.hour, wall.min, wall.sec)
          t.getutc if t.hour == wall.hour && t.min == wall.min
        end
      end

      class IANA
        attr_reader :label

        def self.lookup(name)
          load_tzinfo(name)
          begin
            TZInfo::Timezone.get(name)
          rescue TZInfo::InvalidTimezoneIdentifier
            raise ParseError, "unknown time zone #{name.inspect}"
          end
        end

        def self.load_tzinfo(name)
          require "tzinfo"
        rescue LoadError
          raise ParseError, "time zone #{name.inspect} needs the tzinfo gem (add it to your Gemfile)"
        end

        def initialize(name)
          @tz = self.class.lookup(name)
          @label = name
        end

        def to_wall(time)
          t = @tz.utc_to_local(time.getutc)
          Time.utc(t.year, t.month, t.day, t.hour, t.min, t.sec)
        end

        # nil for wall times skipped by a daylight-saving change; the
        # first occurrence for repeated ones.
        def to_utc(wall)
          @tz.local_to_utc(wall, true)
        rescue TZInfo::PeriodNotFound
          nil
        end
      end
    end
  end
end
