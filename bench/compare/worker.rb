# frozen_string_literal: true

# A server process for the scenario benchmarks: boots one system, defines
# the bench jobs (see Bench::Jobs) and runs an embedded server on the
# "default" queue until TERM or INT. Prints {"pid": ..., "label": ...}
# once its server has started.
#
#   BUNDLE_GEMFILE=bench/compare/Gemfile ruby bench/compare/worker.rb robin
#
# Environment: REDIS_URL, THREADS, POLL, HEARTBEAT, PROCESS_TTL (see
# Bench.server_settings), and FORKS (default 1): with more, the system is
# loaded once and that many server processes are forked from it (sharing
# memory copy-on-write, like `robin swarm`); each prints its own line, and
# TERM to this process stops them all.

require_relative "support"

sys = Bench.system(ARGV.fetch(0))
LABEL = sys.boot
Bench::Jobs.define(sys)
forks = Integer(ENV.fetch("FORKS", 1))

def serve(sys)
  stop = Thread::Queue.new
  %w[TERM INT].each { |sig| trap(sig) { stop << sig } }
  server = sys.server(**Bench.server_settings)
  server.run
  $stdout.puts JSON.generate(pid: Process.pid, label: LABEL)
  $stdout.flush
  stop.pop
  server.stop
end

if forks == 1
  serve(sys)
else
  # Nothing has connected to Redis yet, so the children share no sockets.
  children = Array.new(forks) { fork { serve(sys) } }
  forward = lambda do |sig|
    children.each do |pid|
      Process.kill(sig, pid)
    rescue Errno::ESRCH
      nil # already gone
    end
  end
  %w[TERM INT].each { |sig| trap(sig) { forward.call(sig) } }
  Process.waitall
end
