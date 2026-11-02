# frozen_string_literal: true

require_relative "duel_helper"

# Talking to Redis: encoding commands and parsing replies (the C or Java
# extension where it's loaded), under every command Robin sends.

setup do
  raw = JSON.generate({"class" => "Perf", "args" => [1, "two"], "jid" => "0" * 24, "queue" => "default"})
  @command = ["LPUSH", "robin:queue:default", raw]
  @reply = "*2\r\n$7\r\ndefault\r\n$#{raw.bytesize}\r\n#{raw}\r\n"
end

duel "resp: encode a push of one job" do
  Robin::Redis::ENCODER.encode(@command, +"")
end

duel "resp: parse a fetched job" do
  Robin::Redis::PARSER.parse(@reply, 0)
end

# The pure-Ruby protocol: what Robin runs where neither extension loads.
duel "resp (pure Ruby): encode a push of one job" do
  Robin::Redis::RESP.encode(@command, +"")
end

duel "resp (pure Ruby): parse a fetched job" do
  Robin::Redis::RESP.parse(@reply, 0)
end
