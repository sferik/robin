# frozen_string_literal: true

require "socket"

module Robin
  # A tiny HTTP endpoint a server opens for liveness and readiness probes
  # (Kubernetes, load balancers, uptime monitors):
  #
  #   Robin.configure { |c| c.health_port = 7433 } # or --health-port, ROBIN_HEALTH_PORT
  #
  # Any GET answers 200 while the process is healthy and 503 otherwise,
  # with the details as JSON (see Launcher#health). Swarm children listen
  # on the port plus their index. `robin health` asks the same endpoint, for
  # exec probes.
  class HealthServer
    REASONS = {200 => "OK", 503 => "Service Unavailable"}.freeze
    READ_TIMEOUT = 1
    REQUEST_LIMIT = 16_384

    # The port listened on (assigned by the OS when given 0).
    attr_reader :port

    def initialize(launcher, port:, bind: "0.0.0.0")
      @launcher = launcher
      @server = TCPServer.new(bind, port)
      @port = @server.addr[1]
      @thread = Thread.new do
        Thread.current.name = "robin.health"
        serve
      end
    end

    def stop
      @server.close
      @thread.join(1)
    end

    # The HTTP response for a Launcher#health report.
    def self.response(health)
      code = health.fetch("healthy") ? 200 : 503
      body = Robin.dump_json(health)
      "HTTP/1.1 #{code} #{REASONS.fetch(code)}\r\ncontent-type: application/json\r\n" \
        "content-length: #{body.bytesize}\r\nconnection: close\r\n\r\n#{body}"
    end

    private

    def serve
      loop { answer(@server.accept) }
    rescue IOError, SystemCallError
      nil # closed by #stop
    end

    # Waits briefly for the request (whatever it says), answers and hangs
    # up. A silent client is dropped without an answer. The request is read
    # first: closing a socket with unread data resets the connection, and
    # the client could lose the answer.
    def answer(client)
      return unless client.wait_readable(READ_TIMEOUT)

      client.readpartial(REQUEST_LIMIT)
      client.write(self.class.response(@launcher.health))
    rescue IOError, SystemCallError
      nil # the client went away
    ensure
      client.close
    end
  end
end
