# frozen_string_literal: true

require "socket"

# A connected pair of sockets: Unix ones where there are, else TCP over
# loopback (JRuby on Windows has no UNIXSocket).
module SocketPair
  def self.open
    return UNIXSocket.pair if defined?(UNIXSocket)

    server = TCPServer.new("127.0.0.1", 0)
    [TCPSocket.new("127.0.0.1", server.addr[1]), server.accept].tap { server.close }
  end
end
