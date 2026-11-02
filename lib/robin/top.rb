# frozen_string_literal: true

require "io/console"

module Robin
  # A live view of a cluster in the terminal: `robin top`.
  #
  # Three views, refreshed every +interval+ seconds: the overview (totals
  # and queues), processes, and the jobs running right now. Keys: 1, 2
  # and 3 (or tab) switch views, r refreshes, q quits. It only reads, so
  # it's safe to leave running anywhere.
  class Top
    VIEWS = %w[Overview Processes Busy].freeze
    QUIT = ["q", "Q", "\u0003", "\u0004"].freeze
    DEFAULT_SIZE = [24, 80] #: [Integer, Integer]
      .freeze
    # Bytes of key presses read at once.
    KEY_BUFFER = 64

    # Everything one frame shows, read from Redis in one go.
    Snapshot = Struct.new(:stats, :queues, :processes, :work, :at)

    class Snapshot
      def self.take(config)
        paused = Queue.paused(config: config)
        queues = Queue.all(config: config).map { |q| [q.name, q.size, q.latency, paused.include?(q.name)] } #: Array[Top::queue_row]
        new(Stats.new(config: config), queues.sort_by { |name, size| [-size, name] },
          ProcessSet.new(config: config).to_a, WorkSet.new(config: config).to_a, Robin.now_ms)
      end
    end

    def initialize(config: Robin.config, input: $stdin, output: $stdout, interval: 2)
      @config = config
      @input = input
      @output = output
      @interval = interval
      @view = 0
    end

    attr_reader :view

    # Runs until a quit key (or the end of input).
    def run
      @output.write("\e[?1049h\e[?25l")
      @input.tty? ? @input.raw { loop_frames } : loop_frames
    ensure
      @output.write("\e[?25h\e[?1049l")
      @output.flush
    end

    # One frame for a terminal +height+ lines by +width+ columns.
    def frame(height, width)
      lines = begin
        body(Snapshot.take(@config))
      rescue => e
        ["", "Can't read from Redis: #{e.class}: #{e}", "Retrying every #{@interval}s."]
      end
      [header(width), tabs, *lines].first(height).map { |line| fit(line, width) }
    end

    # Acts on a key press; false means quit.
    def key(char)
      case char
      when *QUIT then return false
      when "1", "2", "3" then @view = Integer(char) - 1
      when "\t" then @view = (@view + 1) % VIEWS.size
      end
      true
    end

    private

    def loop_frames
      loop do
        height, width = size
        @output.write("\e[H", frame(height, width).map { |l| "#{l}\e[K" }.join("\r\n"), "\e[J")
        @output.flush
        next unless @input.wait_readable(@interval)

        chars = @input.read_nonblock(KEY_BUFFER, exception: false)
        break if chars.nil? # the end of input
        next if chars == :wait_readable
        break unless chars.each_char.all? { |c| key(c) }
      end
    end

    def size
      height, width = @output.winsize
      (height.positive? && width.positive?) ? [height, width] : DEFAULT_SIZE
    rescue SystemCallError, NoMethodError
      DEFAULT_SIZE
    end

    def header(width)
      left = "Robin #{VERSION}"
      right = Time.at(Rational(Robin.now_ms, 1000)).strftime("%H:%M:%S")
      left + " " * [width - left.size - right.size, 1].max + right
    end

    def tabs
      views = VIEWS.each_with_index.map { |name, i| (i == @view) ? "[#{i + 1} #{name}]" : " #{i + 1} #{name} " }
      "#{views.join(" ")}   tab next · r refresh · q quit"
    end

    def body(snap)
      case @view
      when 0 then overview(snap)
      when 1 then processes(snap)
      else busy(snap)
      end
    end

    def overview(snap)
      s = snap.stats
      busy = "#{s.workers_size}/#{snap.processes.sum { |p| p["concurrency"].to_i }}"
      [
        "",
        pairs({"Processed" => number(s.processed), "Failed" => number(s.failed), "Busy" => busy,
          "Enqueued" => number(s.enqueued)}),
        pairs({"Scheduled" => number(s.scheduled_size), "Retries" => number(s.retry_size),
          "Dead" => number(s.dead_size), "Processes" => number(snap.processes.size)}),
        ""
      ] + table(%w[QUEUE SIZE LATENCY], snap.queues.map do |name, size, latency, paused|
        [paused ? "#{name} (paused)" : name, number(size), duration(latency)]
      end, right: [1, 2], empty: "No queues")
    end

    def processes(snap)
      rows = snap.processes.map do |p|
        flags = [("leader" if p.leader?), ("quiet" if p.quiet?)].compact.join(", ")
        name = [p["hostname"], p["pid"]].compact.join(":")
        name = "#{name} [#{p["tag"]}]" if p["tag"]
        [name, "#{p.busy}/#{p["concurrency"].to_i}", megabytes(p.rss), since(snap.at, p.started_at),
          since(snap.at, p.beat), flags, p["queues"].to_a.join(", ")]
      end
      [""] + table(%w[PROCESS BUSY RSS UP BEAT STATUS QUEUES], rows, right: [1, 2, 3, 4], empty: "No processes")
    end

    def busy(snap)
      rows = snap.work.sort_by { |_, _, work| work.fetch("run_at") }.map do |identity, tid, work|
        job = JobRecord.new(work.fetch("payload"))
        [identity, tid, work.fetch("queue"), job.display_class, since(snap.at, work.fetch("run_at")), Robin.dump_json(job.display_args)]
      end
      [""] + table(%w[PROCESS THREAD QUEUE JOB RUNNING ARGS], rows, right: [4], empty: "Nothing running")
    end

    # Columns padded to their widest cell; +right+ lists the columns
    # aligned right (numbers).
    def table(headers, rows, right:, empty:)
      return ["  #{empty}"] if rows.empty?

      widths = headers.each_index.map { |i| [headers, *rows].map { |r| r.fetch(i).size }.max }
      [headers, *rows].map do |row|
        row.each_with_index.map { |cell, i| right.include?(i) ? cell.rjust(widths.fetch(i)) : cell.ljust(widths.fetch(i)) }.join("  ").rstrip
      end
    end

    def pairs(hash) = hash.map { |label, value| "#{label} #{value}" }.join("   ")

    def fit(line, width) = (line.size > width) ? "#{line[0, width - 1]}…" : line

    def number(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

    def megabytes(kb) = "#{(kb / 1024.0).round} MB"

    # How long ago +ms+ (epoch milliseconds) was, before +now+.
    def since(now, ms) = ms ? duration((now - ms) / 1000.0) : "-"

    def duration(seconds)
      seconds = [seconds.to_f, 0.0].max
      if seconds < 60 then "#{seconds.round(1)}s"
      elsif seconds < 3600 then "#{(seconds / 60).floor}m #{(seconds % 60).floor}s"
      elsif seconds < 86_400 then "#{(seconds / 3600).floor}h #{(seconds % 3600 / 60).floor}m"
      else "#{(seconds / 86_400).floor}d #{(seconds % 86_400 / 3600).floor}h"
      end
    end
  end
end
