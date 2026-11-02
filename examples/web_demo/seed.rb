# frozen_string_literal: true

# Fills Redis with realistic-looking Robin data for exploring the dashboard.
#
#   ruby examples/web_demo/seed.rb            # seed (wipes previous demo data)
#   ruby examples/web_demo/seed.rb --clear    # remove demo data
#
# Uses redis://127.0.0.1:6379/15 and the "robindemo:" key prefix unless
# ROBIN_DEMO_REDIS_URL / ROBIN_DEMO_PREFIX say otherwise.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "robin"

config = Robin.config
config.redis = {url: ENV.fetch("ROBIN_DEMO_REDIS_URL", "redis://127.0.0.1:6379/15")}
config.key_prefix = ENV.fetch("ROBIN_DEMO_PREFIX", "robindemo:")
config.logger = Logger.new(nil)
srand(42)

def wipe(config)
  config.redis do |c|
    cursor = "0"
    loop do
      cursor, keys = c.call("SCAN", cursor, "MATCH", "#{config.key_prefix}*", "COUNT", 1000)
      c.call("UNLINK", *keys) unless keys.empty?
      break if cursor == "0"
    end
  end
end

wipe(config)
if ARGV.include?("--clear")
  puts "Removed demo data under #{config.key_prefix}*"
  exit
end

NOW = Robin.now_ms
MIN = 60_000

JOBS = {
  "OrderMailer::Confirmation" => {queue: "mailers", args: -> { [rand(10_000..99_999), "en-US"] }, ms: 180},
  "Billing::ChargeInvoice" => {queue: "critical", args: -> { [{"invoice_id" => rand(1..90_000), "attempt" => 1}] }, ms: 640},
  "Search::ReindexProduct" => {queue: "default", args: -> { [rand(1..500_000)] }, ms: 45},
  "Media::TranscodeVideo" => {queue: "low", args: -> { ["s3://uploads/#{SecureRandom.hex(6)}.mov", {"preset" => "1080p"}] }, ms: 14_000},
  "Webhooks::Deliver" => {queue: "webhooks", args: -> { ["https://hooks.example.com/#{SecureRandom.hex(4)}", {"event" => "order.paid"}] }, ms: 320},
  "Reports::NightlyRevenue" => {queue: "reports", args: -> { [Time.now.strftime("%Y-%m-%d")] }, ms: 52_000},
  "Analytics::TrackEvent" => {queue: "default", args: -> { ["page_view", {"user_id" => rand(1..80_000)}] }, ms: 9}
}.freeze

ERRORS = [
  ["Net::ReadTimeout", "Net::ReadTimeout with #<TCPSocket:(closed)>"],
  ["Stripe::CardError", "Your card was declined. (decline_code: insufficient_funds)"],
  ["ActiveRecord::RecordNotFound", "Couldn't find Product with 'id'=48213"],
  ["Faraday::ConnectionFailed", "Failed to open TCP connection to hooks.example.com:443 (getaddrinfo: nodename nor servname provided)"],
  ["Aws::S3::Errors::NoSuchKey", "The specified key does not exist."],
  ["JSON::ParserError", "unexpected character: '<html>' at line 1 column 1"]
].freeze

def backtrace(klass)
  file = klass.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
  [
    "app/jobs/#{file}.rb:#{rand(12..80)}:in 'perform'",
    "app/services/#{file.split("/").last}_service.rb:#{rand(10..200)}:in 'call'",
    "/usr/local/bundle/gems/faraday-2.12.0/lib/faraday/connection.rb:198:in 'post'",
    "/usr/local/bundle/gems/robin-#{Robin::VERSION}/lib/robin/processor.rb:144:in 'perform'",
    "/usr/local/bundle/gems/robin-#{Robin::VERSION}/lib/robin/middleware.rb:120:in 'traverse'",
    "/usr/local/lib/ruby/3.4.0/monitor.rb:201:in 'synchronize'"
  ]
end

def payload(klass, extra = {})
  spec = JOBS.fetch(klass)
  {"class" => klass, "args" => spec[:args].call, "queue" => spec[:queue], "jid" => Robin.generate_jid,
   "retry" => true, "created_at" => NOW - rand(1..3600) * 1000}.merge(extra)
end

config.redis do |c|
  # -- queues -----------------------------------------------------------------
  {"default" => 140, "critical" => 6, "mailers" => 880, "low" => 3_500, "webhooks" => 42, "reports" => 1}.each do |queue, count|
    klasses = JOBS.select { |_, s| s[:queue] == queue }.keys
    oldest = {"mailers" => 95, "low" => 640, "webhooks" => 20}.fetch(queue, 2)
    entries = Array.new(count) do |i|
      at = NOW - ((count - i).to_f / count * oldest * 1000).to_i
      p = payload(klasses.sample, "enqueued_at" => at)
      p["tags"] = ["tenant:acme"] if i.even? && queue == "mailers"
      Robin.dump_json(p)
    end
    entries.each_slice(500) { |slice| c.call("LPUSH", config.key("queue", queue), *slice) }
    c.call("SADD", config.key("queues"), queue)
  end
  c.call("SADD", config.key("paused"), "webhooks")

  # -- scheduled, retries, dead -----------------------------------------------
  48.times do
    p = payload(JOBS.keys.sample)
    at = NOW + rand(30..86_400) * 1000
    c.call("ZADD", config.key("schedule"), at, Robin.dump_json(p.merge("at" => at)))
  end
  36.times do
    klass = JOBS.keys.sample
    err = ERRORS.sample
    failures = rand(1..12)
    at = NOW + rand(20..40_000) * 1000
    p = payload(klass, "error_class" => err[0], "error_message" => err[1], "failures" => failures,
      "failed_at" => NOW - rand(1..72) * 3600_000, "retried_at" => NOW - rand(1..3000) * 1000,
      "error_backtrace" => backtrace(klass), "backtrace" => true, "at" => at)
    c.call("ZADD", config.key("retry"), at, Robin.dump_json(p))
  end
  14.times do
    klass = JOBS.keys.sample
    err = ERRORS.sample
    died = NOW - rand(1..20 * 86_400) * 1000
    p = payload(klass, "error_class" => err[0], "error_message" => err[1], "failures" => 21,
      "failed_at" => died - 10 * 86_400_000, "retried_at" => died, "error_backtrace" => backtrace(klass))
    c.call("ZADD", config.key("dead"), died, Robin.dump_json(p))
  end

  # -- processes, running jobs, progress ----------------------------------------
  processes = [
    {host: "worker-1.prod", tag: "app", queues: %w[critical default mailers], concurrency: 10, busy: 7, leader: true, rss: 412_000},
    {host: "worker-2.prod", tag: "app", queues: %w[critical default mailers], concurrency: 10, busy: 4, leader: false, rss: 398_500},
    {host: "media-1.prod", tag: "media", queues: %w[low reports], concurrency: 4, busy: 3, leader: false, rss: 1_310_000},
    {host: "worker-3.prod", tag: "app", queues: %w[webhooks default], concurrency: 5, busy: 1, leader: false, rss: 288_000, quiet: true}
  ]
  processes.each_with_index do |pr, i|
    identity = "#{pr[:host]}:#{4100 + i * 7}:#{SecureRandom.hex(4)}"
    info = {"identity" => identity, "hostname" => pr[:host], "pid" => 4100 + i * 7, "tag" => pr[:tag], "labels" => [],
            "started_at" => NOW - rand(2..90) * 3600_000, "version" => Robin::VERSION, "ruby" => RUBY_DESCRIPTION,
            "env" => "production", "embedded" => false, "concurrency" => pr[:concurrency], "queues" => pr[:queues],
            "capsules" => {"default" => {"concurrency" => pr[:concurrency], "queues" => pr[:queues].to_h { |q| [q, 0] }}}}
    key = config.key("proc", identity)
    c.call("SADD", config.key("processes"), identity)
    c.call("HSET", key, "info", Robin.dump_json(info), "beat", NOW - rand(0..4000), "busy", pr[:busy], "quiet", (!!pr[:quiet]).to_s,
      "rss", pr[:rss], "leader", pr[:leader] ? "1" : "0", "rtt_us", rand(180..900))
    c.call("EXPIRE", key, 86_400)
    c.call("SET", config.key("leader"), identity, "PX", 86_400_000) if pr[:leader]
    pr[:busy].times do |t|
      queue = pr[:queues].sample
      klass = JOBS.select { |_, s| s[:queue] == queue }.keys.sample || "Search::ReindexProduct"
      job = payload(klass, "queue" => queue, "enqueued_at" => NOW - 5000)
      c.call("HSET", "#{key}:work", "robin.default.#{t}", Robin.dump_json({"queue" => queue, "payload" => job, "run_at" => NOW - rand(1..400) * 1000}))
      if klass == "Media::TranscodeVideo" || klass == "Reports::NightlyRevenue" || t.zero?
        pct = rand(5..95)
        c.call("SET", config.key("progress", job["jid"]), Robin.dump_json({"pct" => pct, "msg" => "#{pct * 12} of 1,200 segments", "at" => NOW}), "EX", 86_400)
      end
    end
    c.call("EXPIRE", "#{key}:work", 86_400)
  end

  # -- metrics ------------------------------------------------------------------
  total_processed = 0
  total_failed = 0
  (0...480).each do |i|
    t = Time.at((NOW - i * MIN) / 1000)
    stamp = Robin::Metrics.minute_stamp(t)
    wave = 1 + 0.45 * Math.sin(i / 37.0) + 0.2 * Math.sin(i / 7.0)
    fields = []
    JOBS.each do |klass, spec|
      base = {"Analytics::TrackEvent" => 260, "Search::ReindexProduct" => 140, "OrderMailer::Confirmation" => 70,
              "Webhooks::Deliver" => 45, "Billing::ChargeInvoice" => 22, "Media::TranscodeVideo" => 4, "Reports::NightlyRevenue" => 0.2}[klass]
      n = (base * wave * (0.85 + rand * 0.3)).round
      n = (rand < 0.2) ? 1 : 0 if base < 1
      next if n.zero?

      f = (rand < 0.07) ? rand(1..[3, n].min) : 0
      f += rand(5..14) if klass == "Webhooks::Deliver" && i.between?(95, 110) # an outage an hour and a half ago
      f = [f, n].min
      fields.push("#{klass}|s", n - f)
      fields.push("#{klass}|f", f) if f > 0
      fields.push("#{klass}|ms", (n * spec[:ms] * (0.7 + rand * 0.6)).round(1))
      hist = config.key("h", klass, stamp)
      buckets = Hash.new(0)
      n.times { buckets[Robin::Metrics.bucket_for(spec[:ms] * Math.exp((rand - 0.5) * 1.6))] += 1 }
      c.call("HSET", hist, *buckets.flatten)
      c.call("EXPIRE", hist, 8 * 3600)
      total_processed += n
      total_failed += f
    end
    c.call("HSET", config.key("m", stamp), *fields) unless fields.empty?
    c.call("EXPIRE", config.key("m", stamp), 8 * 3600)

    sizes = {"default" => 140, "critical" => 6, "mailers" => 880, "low" => 3500, "webhooks" => 42}
    qfields = sizes.flat_map do |q, s|
      ["#{q}|size", (s * (0.4 + wave * 0.5 + rand * 0.2)).round, "#{q}|latency", (q == "low") ? rand(300..700) : rand(0..40)]
    end
    c.call("HSET", config.key("qm", stamp), *qfields)
    c.call("EXPIRE", config.key("qm", stamp), 8 * 3600)
  end

  (0...720).each do |h|
    t = Time.at((NOW - h * 3_600_000) / 1000)
    daily = 1 + 0.5 * Math.sin((t.hour - 6) / 24.0 * 2 * Math::PI)
    fields = JOBS.keys.flat_map do |klass|
      n = (rand(800..1600) * daily * ((klass == "Analytics::TrackEvent") ? 6 : 1)).round
      f = (n * rand * 0.03).round
      ["#{klass}|s", n - f, "#{klass}|f", f, "#{klass}|ms", (n * JOBS[klass][:ms]).round(1)]
    end
    c.call("HSET", config.key("mh", Robin::Metrics.hour_stamp(t)), *fields)
    qfields = %w[default critical mailers low webhooks].flat_map { |q| ["#{q}|size", (rand(10..900) * daily).round, "#{q}|latency", rand(0..120)] }
    c.call("HSET", config.key("qh", Robin::Metrics.hour_stamp(t)), *qfields)
  end

  (0...90).each do |d|
    day = Time.at(NOW / 1000 - d * 86_400).utc.strftime("%Y-%m-%d")
    processed = (480_000 + 120_000 * Math.sin(d / 3.0) + rand(-30_000..30_000)).round
    processed = (processed * 0.62).round if [5, 6].include?(Time.at(NOW / 1000 - d * 86_400).utc.wday) # quiet weekends
    failed = (processed * (0.004 + rand * 0.01)).round
    failed += 9_000 if d == 11
    c.call("SET", config.key("stat", "processed", day), processed)
    c.call("SET", config.key("stat", "failed", day), failed)
    total_processed += processed
    total_failed += failed
  end
  c.call("SET", config.key("stat", "processed"), total_processed)
  c.call("SET", config.key("stat", "failed"), total_failed)
end

# -- optional modules -------------------------------------------------------------
extras = []
begin
  if Robin::Batch.respond_to?(:list) && Robin::Batch.method_defined?(:jobs)
    b = Robin::Batch.new
    b.description = "Import 1,000 products from supplier feed" if b.respond_to?(:description=)
    b.jobs { 12.times { |i| Robin::Client.push("class" => "Search::ReindexProduct", "args" => [i], "queue" => "default") } }
    extras << "batch"
  end
rescue => e
  warn "skipped batches: #{e.class}: #{e.message}"
end
begin
  if Robin::Limiter.respond_to?(:concurrent)
    Robin::Limiter.concurrent("stripe-api", 8).within_limit { nil }
    Robin::Limiter.bucket("sendgrid", 600, :minute).within_limit { nil } if Robin::Limiter.respond_to?(:bucket)
    extras << "limiters"
  end
rescue => e
  warn "skipped limiters: #{e.class}: #{e.message}"
end

begin
  if Robin::Periodic.respond_to?(:list)
    registry = Robin::Periodic::Registry.new
    [
      ["*/5 * * * *", "Search::ReindexProduct", {queue: "default", args: [0], description: "Catch up on stale search documents"}],
      ["0 3 * * *", "Reports::NightlyRevenue", {queue: "reports", tz: "America/Chicago", description: "Email the nightly revenue report"}],
      ["*/15 * * * *", "Webhooks::Deliver", {queue: "webhooks", args: ["https://status.example.com/ping", {}]}],
      ["0 */6 * * *", "Media::TranscodeVideo", {queue: "low", args: ["s3://uploads/backlog", {"preset" => "720p"}]}]
    ].each do |cron, klass, opts|
      id = registry.register(cron, klass, **opts)
      config.redis do |c|
        c.call("HSET", config.key("periodic"), id, Robin.dump_json(registry.entries[id]))
        c.call("HSET", config.key("periodic", "armed"), id, NOW - 30 * 86_400_000)
        step = {"*/5 * * * *" => 5, "*/15 * * * *" => 15, "0 */6 * * *" => 360, "0 3 * * *" => 1440}[cron]
        runs = Array.new(12) { |i| Robin.dump_json({"at" => NOW - (i + 1) * step * MIN, "jid" => Robin.generate_jid}) }
        c.call("RPUSH", config.key("periodic", id, "h"), *runs)
      end
    end
    Robin::Periodic.pause!(registry.entries.keys.last, config: config)
    extras << "cron"
  end
rescue => e
  warn "skipped cron: #{e.class}: #{e.message}"
end

begin
  # Real profiles of a few demo runs (needs the vernier gem).
  raise LoadError, "no vernier" unless Robin::Profiler.available?(config)

  [["Reports::NightlyRevenue", "monthly close", true, 200_000], ["Media::TranscodeVideo", nil, false, 60_000],
    ["Search::ReindexProduct", nil, true, 20_000]].each do |klass, label, ok, n|
    payload = {"jid" => Robin.generate_jid, "class" => klass, "queue" => "default", "profile" => label || true}
    begin
      Robin::Profiler.profile(config, payload) do
        n.times { |i| i.to_s * 3 }
        raise "transcoder exited with status 1" unless ok
      end
    rescue RuntimeError
      nil
    end
  end
  extras << "profiles"
rescue LoadError, StandardError => e
  warn "skipped profiles: #{e.class}: #{e.message}"
end

puts "Seeded demo data under #{config.key_prefix}* #{"(plus #{extras.join(", ")})" unless extras.empty?}"
