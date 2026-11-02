# frozen_string_literal: true

module Robin
  # Cooperative job cancellation.
  #
  #   jid = ExportJob.perform_async(account.id)
  #   Robin.cancel!(jid)
  #   Robin.cancel!(*jids)  # several in one round trip
  #
  # Jobs not yet started are skipped when fetched. Running jobs see
  # #cancelled? turn true and should return early. Servers refresh their
  # local copy of the cancellation list on every heartbeat, so the
  # fetch-time check costs no extra Redis round-trip.
  #
  # A cancelled batch (Robin::Batch#cancel!) is listed as "batch:<bid>",
  # and cancels every job in it the same way.
  module Cancellation
    @cache = {}

    class << self
      def cancel!(*jids, ttl: 86_400, config: Robin.config)
        jids = jids.flatten
        return true if jids.empty?

        expires = Robin.now_ms + ttl * 1000
        config.redis do |c|
          c.pipelined do |p|
            p.call("ZADD", config.key("cancelled"), *jids.flat_map { |jid| [expires, jid] })
            p.call("ZREMRANGEBYSCORE", config.key("cancelled"), "-inf", Robin.now_ms)
          end
        end
        @cache[config.object_id]&.merge(jids)
        true
      end

      # Live check against Redis: was the job, or its batch, cancelled?
      def cancelled?(jid, bid: nil, config: Robin.config)
        members = [jid, bid && "batch:#{bid}"].compact
        return false if members.empty?

        config.redis { |c| c.call("ZMSCORE", config.key("cancelled"), *members) }.any?
      end

      # Fast in-memory check used by processors.
      def skip?(config, jid, bid = nil)
        set = @cache[config.object_id]
        !set.nil? && (set.include?(jid) || set.include?("batch:#{bid}"))
      end

      def refresh(config, conn) = store(config, conn.call(*listing(config)))

      # The command that reads the live cancellation list, for a heartbeat
      # to send along with others; pass its reply to #store.
      def listing(config) = ["ZRANGE", config.key("cancelled"), Robin.now_ms, "+inf", "BYSCORE"]

      # Replaces the local copy of the cancellation list.
      def store(config, jids)
        @cache[config.object_id] = Set.new(jids)
      end
    end
  end
end
