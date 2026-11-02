# frozen_string_literal: true

# A TCP proxy that delays every chunk by a fixed time in each direction,
# to measure as if Redis were across a network instead of on localhost.
#
#   ruby bench/compare/latency_proxy.rb LISTEN_PORT UPSTREAM_HOST:PORT MILLIS
#
# Delay is per direction, so 1 means a 2ms round trip. Chunks are
# timestamped when read and written once their delay has passed, so
# pipelined traffic isn't serialized behind earlier chunks' delays.

require "socket"

listen_port, upstream, millis = ARGV
host, port = upstream.split(":")
DELAY = Float(millis) / 1000

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def pump(from, to)
  chunks = Thread::Queue.new
  Thread.new do
    while (chunk = chunks.pop)
      wait = chunk[0] - now
      sleep(wait) if wait.positive?
      to.write(chunk[1])
    end
  rescue IOError, SystemCallError
    nil
  ensure
    begin
      to.close_write
    rescue IOError, SystemCallError
      nil # the other direction closed it first
    end
  end
  loop { chunks << [now + DELAY, from.readpartial(65_536)] }
rescue IOError, SystemCallError
  chunks.close
end

server = TCPServer.new("127.0.0.1", Integer(listen_port))
$stdout.puts "ready"
$stdout.flush
loop do
  client = server.accept
  Thread.new do
    redis = TCPSocket.new(host, Integer(port))
    [client, redis].each { |s| s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) }
    up = Thread.new { pump(client, redis) }
    pump(redis, client)
    up.join
  rescue IOError, SystemCallError
    nil
  ensure
    [client, redis].each { |s| s&.close unless s&.closed? }
  end
end
