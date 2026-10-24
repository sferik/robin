# frozen_string_literal: true

require "socket"

module Robin
  # Tells systemd how the server is doing, when it runs as a Type=notify
  # service (systemd sets NOTIFY_SOCKET):
  #
  #   [Service]
  #   Type=notify
  #   WatchdogSec=30
  #   ExecStart=/usr/bin/bundle exec robin
  #
  # The server reports READY=1 once it's working, STOPPING=1 when it
  # starts shutting down, and, with WatchdogSec, pets the watchdog from its
  # heartbeat (so keep WatchdogSec at several heartbeat intervals). Without
  # NOTIFY_SOCKET every call is a no-op.
  module Systemd
    # Sends +state+ (e.g. "READY=1"). True if it was sent.
    def self.notify(state, env: ENV)
      path = env["NOTIFY_SOCKET"].to_s
      return false if path.empty?

      Socket.open(:UNIX, :DGRAM) do |sock|
        sock.connect(Socket.sockaddr_un(address(path)))
        sock.write(state)
      end
      true
    rescue SystemCallError, IOError, ArgumentError, SocketError # (JRuby has no datagram Unix sockets)
      false
    end

    # A leading "@" means Linux's abstract socket namespace.
    def self.address(path)
      path.start_with?("@") ? "\0#{path[1..]}" : path
    end

    # Whether systemd watches this process (WatchdogSec is set, and is
    # meant for this pid).
    def self.watchdog?(env: ENV, pid: Process.pid)
      return false unless env["WATCHDOG_USEC"].to_i.positive?

      watched = env["WATCHDOG_PID"].to_s
      watched.empty? || Integer(watched, exception: false) == pid
    end
  end
end
