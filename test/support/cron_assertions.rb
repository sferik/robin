# frozen_string_literal: true

# Robin::Cron#match? isn't a Regexp-style matcher, so these stand in for
# assert_match/refute_match.
module CronAssertions
  def assert_fires(cron, time, message = nil)
    fired = cron.match?(time)
    message ||= "expected #{cron.inspect} to fire at #{time}"

    assert fired, message
  end

  def refute_fires(cron, time, message = nil)
    fired = cron.match?(time)
    message ||= "expected #{cron.inspect} not to fire at #{time}"

    refute fired, message
  end
end
