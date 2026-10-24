# frozen_string_literal: true

# Deterministic checks that code takes a lock: hold the lock in another
# thread and verify the block can't finish until it's released.
module LockAssertions
  def assert_waits_for(lock, &)
    held = Queue.new
    release = Queue.new
    holder = Thread.new { lock.synchronize { held << true; release.pop } } # rubocop:disable Style/Semicolon
    held.pop
    worker = Thread.new(&)

    assert_nil worker.join(0.2), "finished while another thread held the lock"
    release << true
    holder.join
    worker.value
  end
end
