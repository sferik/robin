# frozen_string_literal: true

require_relative "duel_helper"

# Crash recovery: the leader looks for dead processes on every leader
# beat, and puts the jobs a dead one had in flight back on their queues.

setup { configure_robin }

# Every check: ten processes, all alive.
duel "recovery: a check with every process alive" do
  once do
    Robin.redis do |c|
      c.pipelined do |p|
        10.times do |i|
          set = Robin.config.key("inflight", "live:#{i}")
          p.call("SADD", Robin.config.key("inflights"), set)
          p.call("SADD", Robin.config.key("processes"), "live:#{i}")
          p.call("SET", Robin.config.process_key("live:#{i}"), "1")
        end
      end
    end
  end
  Robin::Recovery.run(Robin.config)
end

# A crashed process's n jobs, each in an in-flight key of its own (as
# Robin::Fetcher leaves them).
duel "recovery: recovering a dead process's jobs" do |n|
  once do
    @raw = JSON.generate({"class" => "Perf", "args" => [1, "two"], "queue" => "default", "jid" => "JID"})
    @dead = 0
  end
  untimed do
    config = Robin.config
    set = config.key("inflight", identity = "dead:#{@dead += 1}")
    Robin.redis do |c|
      c.pipelined do |p|
        p.call("DEL", config.key("queue", "default"))
        n.times do |i|
          p.call("SADD", set, "#{set}:#{i}")
          # Every job new, so none counts as a poison pill.
          p.call("RPUSH", "#{set}:#{i}", @raw.sub("JID", "#{@dead}.#{i}"))
        end
        p.call("SADD", config.key("inflights"), set)
        p.call("SADD", config.key("processes"), identity)
      end
    end
  end
  Robin::Recovery.run(Robin.config)
end
