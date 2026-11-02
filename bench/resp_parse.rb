# frozen_string_literal: true

# Compares the pure-Ruby and native RESP parsers on realistic replies.
#
#   rake compile && ruby -Ilib bench/resp_parse.rb

require "robin"
begin
  require "robin_resp/robin_resp"
rescue LoadError
  abort "Native extension not compiled; run `rake compile` first."
end

def bulk(s) = "$#{s.bytesize}\r\n#{s}\r\n"

def array(items) = "*#{items.size}\r\n#{items.join}"

job = Robin.dump_json(
  "class" => "Billing::InvoiceMailerJob", "args" => [123_456, {"locale" => "en", "resend" => false}],
  "queue" => "mailers", "jid" => SecureRandom.hex(12), "retry" => true,
  "created_at" => Robin.now_ms, "enqueued_at" => Robin.now_ms, "tags" => %w[billing email]
)

cases = {
  "single job payload (BLMOVE)" => bulk(job),
  "LRANGE 100 payloads" => array(Array.new(100) { bulk(job) }),
  "LRANGE 1000 payloads" => array(Array.new(1000) { bulk(job) }),
  "HGETALL process (16 fields)" => array(Array.new(16) { |i| bulk("field#{i}") + bulk("value-#{i * 7919}") }),
  "ZRANGE 100 WITHSCORES" => array(Array.new(100) { bulk(job) + bulk((Robin.now_ms + rand(10**6)).to_s) }),
  "pipeline of 20 integers" => ":12345\r\n" * 20
}.transform_values(&:b)

def measure(parser, buf, multi)
  iterations = 0
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = start + 1.0
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    100.times do
      if multi
        pos = 0
        pos = parser.parse(buf, pos)[1] while pos < buf.bytesize
      else
        parser.parse(buf, 0)
      end
    end
    iterations += 100
  end
  iterations / (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
end

puts "reply                                Ruby ops/s        C ops/s  speedup"
cases.each do |name, buf|
  multi = name.start_with?("pipeline")
  ruby = measure(Robin::Redis::RESP, buf, multi)
  native = measure(Robin::Redis::NativeRESP, buf, multi)
  puts format("%-32s %14.0f %14.0f %7.1fx", name, ruby, native, native / ruby)
end
