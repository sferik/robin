# frozen_string_literal: true

module Robin
  # Live progress reporting for long jobs, shown on the web UI's Busy page.
  #
  #   def perform(ids)
  #     ids.each_with_index do |id, i|
  #       process(id)
  #       progress!((i + 1) * 100 / ids.size, "#{i + 1}/#{ids.size} rows")
  #     end
  #   end
  module Progress
    TTL = 86_400

    class << self
      def report(jid, percent, message = nil, meta = {}, config: Robin.config)
        data = entry(percent, message, meta)
        config.redis { |c| c.call(*set_command(config, jid, data)) }
        data
      end

      # What #report stores. A nil +percent+ is unknown (the Busy page
      # shows the message, or meta's "iterations" count, without a bar).
      def entry(percent, message = nil, meta = {})
        data = {"pct" => percent&.to_f&.clamp(0, 100)&.round(1), "msg" => message, "at" => Robin.now_ms} #: entry
        data["meta"] = meta unless meta.empty?
        data
      end

      # The command #report sends, for callers that batch it with others.
      def set_command(config, jid, data) = ["SET", config.key("progress", jid), Robin.dump_json(data), "EX", TTL]

      def fetch(jid, config: Robin.config)
        raw = config.redis { |c| c.call("GET", config.key("progress", jid)) }
        raw && Robin.load_json(raw)
      end

      def fetch_many(jids, config: Robin.config)
        return {} if jids.empty?

        values = config.redis { |c| c.call("MGET", *jids.map { |j| config.key("progress", j) }) }
        jids.zip(values).each_with_object({}) { |(j, v), h| h[j] = Robin.load_json(v) if v }
      end
    end
  end
end
