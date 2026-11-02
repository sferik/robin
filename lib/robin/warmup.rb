# frozen_string_literal: true

module Robin
  # Warms up the JIT before a server starts (see Config#jit_warmup): runs
  # the code that pushes, fetches and runs jobs many times over, so it's
  # compiled before real jobs come. A cold JRuby process pushes and runs
  # jobs several times slower than a warm one for its first seconds.
  #
  # Nothing reaches Redis: the commands are encoded and canned replies
  # parsed by a connection that sends nothing. Only Robin's own middleware
  # runs (the app's may have side effects), with jobs that use none of
  # its features, and no job is performed.
  module Warmup
    ROUNDS = 500

    # Every round pushes this many jobs in bulk, then this many again one
    # at a time, and fetches and runs as many.
    JOBS = 100

    ARGS = [1, "two", {"three" => 3.0, "four" => [4]}].freeze

    # A connection that encodes each round trip's commands and answers
    # every one of them with +reply+ (RESP), parsed as a reply from Redis
    # would be.
    class Connection < Redis::Connection
      # mutant:disable -- it never connects, so where to doesn't matter.
      def initialize(reply)
        super(host: "warmup")
        @reply = reply
      end

      private

      # mutant:disable -- the replies are all in the buffer, so reading
      # them never waits (whatever the timeout).
      def roundtrip(commands, _read_timeout)
        encode(commands)
        commands.each { @buf << @reply }
        Array.new(commands.size) { read_reply(0) }
      end
    end

    # A pool of the one connection, for client middleware.
    Pool = Struct.new(:connection)

    class Pool
      def with = yield(connection)
    end

    class << self
      def run(config, rounds: ROUNDS)
        conn = Connection.new(":1\r\n")
        # (A stand-in for a Redis::Pool: it has the #with the client uses.)
        client = Client.new(config: config, pool: Pool.new(conn), chain: own(config.client_middleware)) # steep:ignore ArgumentTypeMismatch
        server = own(config.server_middleware)
        raw = Robin.dump_json(job(client))
        fetches = Connection.new("*2\r\n$7\r\ndefault\r\n$#{raw.bytesize}\r\n#{raw}\r\n")
        rounds.times do
          push_bulk(client, conn)
          JOBS.times { push(client, conn) }
          JOBS.times { fetch_and_run(fetches, server, conn) }
        end
      end

      # A copy of +chain+ with only Robin's own middleware.
      def own(chain)
        chain = chain.dup
        chain.each { |entry| chain.remove(entry.klass) unless entry.klass.to_s.start_with?("Robin::") }
        chain
      end

      private

      def job(client) = client.normalize({"class" => "Robin::Warmup", "args" => ARGS})

      def push_bulk(client, conn)
        template = client.normalize({"class" => "Robin::Warmup", "args" => []})
        payloads = Array.new(JOBS) { client.__send__(:run_middleware, client.__send__(:build, template, ARGS, nil, nil)) }
        conn.pipelined { |p| client.queue_push(p, payloads) }
      end

      def push(client, conn)
        payload = client.__send__(:invoke_middleware, job(client))
        conn.pipelined { |p| client.queue_push(p, [payload]) }
      end

      # The job "runs" by being acknowledged.
      def fetch_and_run(fetches, server, conn)
        _queue, raw = fetches.call("BLMOVE", "queue", "inflight", "RIGHT", "LEFT", 2)
        server.invoke(nil, Robin.load_json(raw), "default") { conn.call("DEL", "inflight") }
      end
    end
  end
end
