# frozen_string_literal: true

module Robin
  # Things worth knowing about that aren't errors, as events: what Robin
  # otherwise only logs. Handlers are callables taking the event's name and
  # a Hash about it:
  #
  #   Robin.configure do |config|
  #     config.event_handlers << ->(name, payload) { Metrics.increment("robin.#{name}") }
  #   end
  #
  # The Rails integration sends them on to ActiveSupport::Notifications as
  # "<name>.robin". The events, and what their payloads hold:
  #
  # job.expired::      job (the payload): it expired before it ran
  # job.skipped::      job, reason ("cancelled" or "superseded", by a later
  #                    debounced push)
  # job.discarded::    job, error: it raised Robin::Discard
  # job.rate_limited:: job, limiter (its name), delay (seconds until it
  #                    runs again)
  # job.recovered::    job, poison (true when it went to the dead set
  #                    instead of its queue): it was running when its
  #                    process died
  # jobs.orphaned::    count: in-flight jobs no worker held, put back
  # jobs.interrupted:: count: jobs still running when a stopping process's
  #                    timeout ran out
  # iteration.slow::   job, seconds: an iterable job's iteration took
  #                    longer than the shutdown timeout
  # worker.started::   capsule (its name): a worker thread started; handlers
  #                    run on that thread
  # worker.died::      error, delay (seconds before its replacement starts;
  #                    nil when stopping, with no replacement)
  # workers.resized::  capsule, from, to: a capsule's worker count changed
  #                    (Robin::Launcher#resize)
  # redis.slow::       rtt_us: Redis round trips take over 50ms
  # gvl.contended::    percent: GVL contention (see Robin::GVL) stayed at 50%
  #                    or more for three heartbeats in a row
  # heartbeat.lapsed:: (nothing): no heartbeat for longer than process_ttl
  # memory.exceeded::  rss_mb, limit_mb: the process restarts gracefully
  # swarm.child_exited:: index, pid, status (exit status or signal), delay
  # push.buffered::    jobs, error: pushed while Redis was unreachable,
  #                    held by reliable push
  # push.dropped::     jobs: reliable push's buffer was full
  # push.recovered::   count: buffered jobs pushed once Redis was back
  # push.lost::        jobs: still buffered when the process exited
  module Events
    # Calls every handler; one that raises is reported and the others
    # still run.
    def self.emit(config, name, **payload)
      config.event_handlers.each do |handler|
        handler.call(name, payload)
      rescue => e
        config.handle_exception(e, {context: "event handler", event: name})
      end
      nil
    end
  end
end
