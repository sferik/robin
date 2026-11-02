# frozen_string_literal: true

# Stands in for Robin::Statsd, recording counters, gauges, timings and
# distributions.
class StatsdRecorder
  attr_reader :calls

  def initialize(dogstatsd: false, distributions: false)
    @calls = []
    @dogstatsd = dogstatsd
    @distributions = distributions
  end

  def dogstatsd? = @dogstatsd

  def distributions? = @distributions

  def increment(name, value = 1, tags: {}) = @calls << [:increment, name, value, tags]

  def gauge(name, value, tags: {}) = @calls << [:gauge, name, value, tags]

  def timing(name, ms, tags: {}) = @calls << [:timing, name, ms, tags]

  def distribution(name, value, tags: {}) = @calls << [:distribution, name, value, tags]

  # A flush's per-class counts (as Robin::Statsd#job_metrics takes them).
  def job_metrics(jobs) = @calls << [:job_metrics, jobs]
end
