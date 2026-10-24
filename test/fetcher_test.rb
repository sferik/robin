# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/runtime"

class FetcherTest < RobinTest
  include RuntimeTestHelpers

  cover "Robin::Fetcher*"

  def setup
    super
    @capsule = config.default_capsule
    @capsule.queues = %w[high low]
    @fetcher = Robin::Fetcher.new(@capsule, "me")
  end

  def set = config.key("inflight", "me")

  def inflight = in_flight(set)

  def registered = redis("SMEMBERS", set).sort

  def queue(name) = redis("LRANGE", config.key("queue", name), 0, -1)

  def push(name, *raws) = redis("LPUSH", config.key("queue", name), *raws)

  def free(fetcher = @fetcher) = fetcher.instance_variable_get(:@free)

  # Gives +fetcher+ +count+ registered, empty in-flight keys, as earlier
  # round trips leave it; returns them.
  def warm(fetcher, count)
    keys = Array.new(count) { "#{fetcher.inflight_key}:#{Robin::Fetcher.mint}" }
    redis("SADD", fetcher.inflight_key, *keys)
    free(fetcher).concat(keys)
    keys
  end

  # Forces the blocking path by making the fetch script find nothing.
  def no_script = ->(kind, _args) { (kind == :evalsha) ? [] : :forward }

  # Nothing to fetch, and nothing arrives while blocked.
  def idle = ->(kind, _args) { {evalsha: [], pipelined: [nil]}.fetch(kind, :forward) }

  # The fetch script runs, but nothing arrives while blocked.
  def unblocked = ->(kind, _args) { (kind == :pipelined) ? [nil] : :forward }

  def test_accessors
    assert_same config, @fetcher.config
    assert_same @capsule, @fetcher.capsule
    assert_equal config.key("inflight", "me"), @fetcher.inflight_key
    assert_empty @fetcher.paused
    assert_equal 2048, Robin::Fetcher::LARGE
    assert_equal 1, Robin::Fetcher::STALE
    assert_false @fetcher.instance_variable_get(:@large)
  end

  def test_mint_numbers_keys_for_the_whole_process
    first = Robin::Fetcher.mint

    assert_equal [first + 1, first + 2], [Robin::Fetcher.mint, Robin::Fetcher.mint]
    minting = Robin::Fetcher.instance_variable_get(:@minting)
    number = minting.synchronize do
      thread = Thread.new { Robin::Fetcher.mint }

      refute thread.join(0.05), "minted without the lock"
      thread
    end

    assert_equal first + 3, number.value
  end

  # Keys it lacks are minted (and registered), not more.
  def test_a_round_trip_mints_only_the_keys_it_lacks
    key, = warm(@fetcher, 1)
    push("high", "h1", "h2")
    others_waiting(@fetcher, 1)
    pool = recording_pool { assert_equal key, @fetcher.fetch.key }
    minted = @fetcher.held.first

    assert_equal [[:pipelined], [:pipe, "SADD", set, minted],
      [:pipe, :evalsha, Robin::Scripts::FETCH, [config.key("paused"), key, minted, config.key("queue", "high"), config.key("queue", "low")],
        [2, "high", "low"]]], pool.calls
    assert_equal [key, minted].sort, registered
  end

  def test_fetch_takes_oldest_job_in_priority_order
    push("low", "l1")
    push("high", "h1", "h2")
    unit = assert_roundtrips(1) { @fetcher.fetch }

    assert_instance_of Robin::Fetcher::UnitOfWork, unit
    assert_equal ["high", "h1", @fetcher], [unit.queue, unit.raw, unit.fetcher]
    assert_match(/\A#{Regexp.escape(set)}:\d+\z/o, unit.key)
    assert_equal [unit.key], registered
    assert_equal %w[h1], redis("LRANGE", unit.key, 0, -1)
    second = @fetcher.fetch

    assert_equal "h2", second.raw
    assert_equal [unit.key, second.key].sort, registered
    assert_equal %w[h1 h2], inflight
    assert_equal "l1", assert_roundtrips(1) { @fetcher.fetch(0, ack: second.key) }.raw, "acknowledges in the same round trip"
    assert_equal %w[h1 l1], inflight
    assert_equal [second.key], free, "acknowledged: free to fill again"
  end

  def test_fetch_skips_paused_queues
    push("high", "h1")
    push("low", "l1")
    redis("SADD", config.key("paused"), "high")

    assert_equal "low", @fetcher.fetch.queue
  end

  # The first round trip registers the key it mints before the script
  # fills it; later ones reuse free keys.
  def test_fetch_registers_new_keys_first
    push("high", "h1", "h2")
    unit = nil
    pool = recording_pool { unit = @fetcher.fetch }

    queues = [config.key("queue", "high"), config.key("queue", "low")]

    assert_equal [[:pipelined], [:pipe, "SADD", set, unit.key],
      [:pipe, :evalsha, Robin::Scripts::FETCH, [config.key("paused"), unit.key, *queues], [1, "high", "low"]]], pool.calls
    second = nil
    pool = recording_pool { second = @fetcher.fetch(0, ack: unit.key) }

    assert_equal [[:pipelined], [:pipe, "SADD", set, second.key],
      [:pipe, :evalsha, Robin::Scripts::FETCH, [config.key("paused"), second.key, *queues, unit.key], [1, "high", "low"]]], pool.calls
    push("high", "h3")
    pool = recording_pool { assert_equal unit.key, @fetcher.fetch(0, ack: second.key).key }

    assert_equal [[:evalsha, Robin::Scripts::FETCH, [config.key("paused"), unit.key, *queues, second.key], [1, "high", "low"]]], pool.calls
  end

  def test_fetch_script_arguments
    keys = warm(@fetcher, 2)
    @fetcher.instance_variable_set(:@acks, ["done"])
    @fetcher.instance_variable_set(:@wanting, 1)
    pool = recording_pool(idle) { @fetcher.fetch }

    assert_equal [:evalsha, Robin::Scripts::FETCH,
      [config.key("paused"), *keys, config.key("queue", "high"), config.key("queue", "low"), "done"], [2, "high", "low"]], pool.calls.first
    assert_equal [*keys, "done"], free, "nothing filled them"
  end

  def test_the_script_fills_keys_in_order_and_acknowledges_first
    push("high", "h1")
    push("low", "l1", "l2", "l3")
    redis("SADD", config.key("paused"), "nothing")
    redis("RPUSH", "#{set}:done", "finished")
    queues = [config.key("queue", "high"), config.key("queue", "low")]
    keys = [config.key("paused"), "#{set}:a", "#{set}:b", "#{set}:c", *queues, "#{set}:done"]
    taken = config.redis { |c| c.evalsha(Robin::Scripts::FETCH, keys, [3, "high", "low"]) }

    assert_equal %w[high h1 low l1 low l2], taken
    assert_equal [%w[h1], %w[l1], %w[l2]], %w[a b c].map { |k| redis("LRANGE", "#{set}:#{k}", 0, -1) }
    assert_equal 0, redis("EXISTS", "#{set}:done")
    assert_equal %w[l3], queue("low")
  end

  def test_the_script_skips_paused_queues_and_stops_when_full
    push("high", "h1", "h2")
    push("low", "l1")
    keys = ->(*names) { [config.key("paused"), *names.map { |k| "#{set}:#{k}" }, config.key("queue", "high"), config.key("queue", "low")] }
    taken = config.redis { |c| c.evalsha(Robin::Scripts::FETCH, keys.call("a"), [1, "high", "low"]) }

    assert_equal %w[high h1], taken
    redis("SADD", config.key("paused"), "high")
    taken = config.redis { |c| c.evalsha(Robin::Scripts::FETCH, keys.call("b", "c"), [2, "high", "low"]) }

    assert_equal %w[low l1], taken, "nothing left after it"
    assert_equal %w[h2], queue("high")
    assert_equal 0, redis("EXISTS", "#{set}:c")
  end

  # The paused check follows the blocking fetch in its pipeline.
  def test_blocking_fetch_targets_slot_queue_and_moves_oldest
    config.fetch_timeout = 3
    key, = warm(@fetcher, 1)
    push("low", "l1", "l2")
    push("high", "h1")
    unit = nil
    pool = recording_pool(no_script) { unit = assert_roundtrips(1) { @fetcher.fetch(3) } }

    # The fetch script, answered by the responder, then the blocking fetch.
    assert_equal [[:evalsha], [:pipelined],
      [:pipe, "BLMOVE", config.key("queue", "low"), key, "RIGHT", "LEFT", 3],
      [:pipe, "SISMEMBER", config.key("paused"), "low"]], pool.calls.map { |c| (c[0] == :evalsha) ? [:evalsha] : c }
    assert_equal ["low", "l1", key], [unit.queue, unit.raw, unit.key]
    assert_same @fetcher, unit.fetcher
    assert_equal %w[l1], inflight
    assert_equal %w[l2], queue("low")
    assert_empty @fetcher.held, "handed out"
  end

  # Only when another worker took the key the fetch script left free.
  def test_blocking_fetch_registers_a_new_key_first
    push("high", "h1")
    unit = nil
    pool = recording_pool { unit = @fetcher.send(:wait, 0, %w[high low]) }

    assert_equal [[:pipelined], [:pipe, "SADD", set, unit.key], [:pipe, "BLMOVE", config.key("queue", "high"), unit.key, "RIGHT", "LEFT", config.fetch_timeout],
      [:pipe, "SISMEMBER", config.key("paused"), "high"]], pool.calls
    assert_equal ["high", "h1"], [unit.queue, unit.raw]
    assert_equal [unit.key], registered
    assert_equal %w[h1], inflight
  end

  # The read waits for the blocking command's timeout on top of the
  # connection's own.
  # Blocking for 0.3s outlasts the 0.2s read timeout. (Redis may answer a
  # blocking command a little after its timeout, hence the margin.)
  def test_blocking_fetch_outwaits_the_read_timeout
    config.redis = {url: REDIS_URL, read_timeout: 0.2}
    config.fetch_timeout = 0.3
    warm(@fetcher, 1)
    blocked = []
    pool = recording_pool(no_script) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_nil @fetcher.fetch(0)
      blocked << Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    assert_operator blocked.first, :>, 0.25
    assert_equal [:evalsha, :pipelined, :pipe, :pipe], pool.calls.map(&:first)
  end

  def test_blocking_fetch_slot_wraps_around_active_queues
    warm(@fetcher, 3)
    push("high", "h1")
    push("low", "l1")
    blocked_on = ->(slot) { recording_pool(no_script) { return @fetcher.fetch(*slot).queue } }

    assert_equal "high", blocked_on.call([2])
    assert_equal "low", blocked_on.call([5])
    push("high", "h2")

    assert_equal "high", blocked_on.call([])
  end

  def test_blocking_fetch_skips_locally_paused_queues
    warm(@fetcher, 1)
    @fetcher.paused = ["high"]
    push("low", "l1")
    unit = nil
    recording_pool(no_script) { unit = @fetcher.fetch(0) }

    assert_equal "low", unit.queue
  end

  def test_blocking_fetch_returns_nil_when_nothing_arrives
    key, = warm(@fetcher, 1)
    result = :unset
    pool = recording_pool(no_script) { result = @fetcher.fetch(0) }

    assert_nil result
    assert_equal [:evalsha, :pipelined, :pipe, :pipe], pool.calls.map(&:first)
    assert_equal [:pipe, "BLMOVE", config.key("queue", "high"), key, "RIGHT", "LEFT", config.fetch_timeout], pool.calls.fetch(2)
    assert_empty queue("high")
    assert_empty inflight
    assert_equal [key], free, "still empty: free"
  end

  # A blocking round trip that fails may have moved a job no one will hear
  # about: its key is let go of (the sweep puts the job back).
  def test_a_failed_blocking_fetch_lets_go_of_its_key
    key, = warm(@fetcher, 1)
    boom = lambda do |kind, _args|
      raise Robin::Redis::TimeoutError, "slow" if kind == :pipelined

      no_script.call(kind, nil)
    end
    assert_raises(Robin::Redis::TimeoutError) { recording_pool(boom) { @fetcher.fetch(0) } }

    assert_empty @fetcher.held
    assert_equal [key], registered
  end

  def test_job_from_queue_paused_while_blocked_is_handed_back
    key, = warm(@fetcher, 1)
    push("high", "h0", "h1")
    redis("SADD", config.key("paused"), "high") # not known to the fetcher yet
    result = :unset
    pool = recording_pool(no_script) { result = @fetcher.fetch(0) }

    assert_nil result
    assert_empty inflight
    assert_equal %w[h1 h0], queue("high"), "back where it was"
    assert_equal [[:tx, "LMOVE", key, config.key("queue", "high"), "RIGHT", "RIGHT"]], pool.calls.select { |c| c[0] == :tx }
    assert_equal [key], free
  end

  # A pause that comes while the worker is blocked, before the job does.
  def test_job_from_queue_paused_during_the_wait_is_handed_back
    config.fetch_timeout = 3
    key, = warm(@fetcher, 1)
    result = :unset
    worker = Thread.new { result = @fetcher.fetch(0) }
    # Until the fetch is waiting: a client blocked in a command (flags=b,
    # as Redis, Valkey and Dragonfly all report it, where only some name
    # the command), for 10 seconds at most.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until redis("CLIENT", "LIST").match?(/ flags=[a-zA-Z]*b/)
      flunk "the fetch never waited" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
    redis("SADD", config.key("paused"), "high")
    push("high", "h1")
    worker.join

    assert_nil result
    assert_empty inflight
    assert_equal %w[h1], queue("high"), "back where it was"
    assert_equal [key], free
  end

  def test_all_queues_paused_sleeps_then_returns_nil
    config.fetch_timeout = 3
    @fetcher.paused = %w[high low]
    warm(@fetcher, 1)
    slept = []
    @fetcher.define_singleton_method(:sleep) { |s| slept << s }
    result = :unset
    pool = recording_pool(no_script) { result = @fetcher.fetch }

    assert_nil result
    assert_equal [3], slept
    assert_equal [:evalsha], pool.calls.map(&:first)
    assert_equal 1, @fetcher.held.size, "no key taken to wait on nothing"
  end

  def test_fetch_acknowledges_even_when_no_job_is_waiting
    done = unit_in_flight(@fetcher, "done", "high")
    warm(@fetcher, 1)
    pool = recording_pool(unblocked) { assert_nil @fetcher.fetch(0, ack: done.key) }

    assert_empty inflight
    assert_equal done.key, pool.calls.first[2].last
    assert_includes free, done.key
  end

  # -- a capsule with one queue fetches single jobs with plain commands ------

  def single_queue
    @capsule.queues = %w[only]
    Robin::Fetcher.new(@capsule, "me")
  end

  # The commands +fetcher+.fetch sends in pipelines.
  def piped_commands(fetcher, ack: nil)
    unit = nil
    pool = recording_pool { unit = fetcher.fetch(0, ack: ack) }
    [unit&.raw, pool.calls.filter_map { |kind, command, *| command if kind == :pipe }]
  end

  def test_a_worker_that_waited_on_the_only_queue_for_nothing_waits_again_at_once
    fetcher = single_queue
    warm(fetcher, 1)

    assert_equal [nil, %w[SISMEMBER LMOVE BLMOVE SISMEMBER]], piped_commands(fetcher)
    assert_equal [nil, %w[BLMOVE SISMEMBER]], piped_commands(fetcher)
    assert_equal [nil, %w[BLMOVE SISMEMBER]], piped_commands(fetcher), "still idle"
    push("only", "j1", "j2")

    assert_equal ["j1", %w[BLMOVE SISMEMBER]], piped_commands(fetcher)
    warm(fetcher, 1)

    assert_equal ["j2", %w[DEL SISMEMBER LMOVE]], piped_commands(fetcher, ack: "x"), "busy again"
  end

  def test_a_worker_waiting_on_one_of_several_queues_fetches_first
    warm(@fetcher, 1)
    2.times do
      pool = recording_pool(no_script) { assert_nil @fetcher.fetch }

      assert_equal :evalsha, pool.calls.first.first
    end
  end

  def test_a_failed_wait_does_not_count_as_waiting_for_nothing
    fetcher = single_queue
    warm(fetcher, 1)
    pipelines = 0
    boom = lambda do |kind, _args|
      raise Robin::Redis::TimeoutError, "slow" if kind == :pipelined && (pipelines += 1) == 2

      :forward
    end
    assert_raises(Robin::Redis::TimeoutError) { recording_pool(boom) { fetcher.fetch } }
    warm(fetcher, 1)

    assert_equal [nil, %w[SISMEMBER LMOVE BLMOVE SISMEMBER]], piped_commands(fetcher)
  end

  def test_waiting_for_nothing_is_each_workers_own
    fetcher = single_queue
    warm(fetcher, 2)
    recording_pool { fetcher.fetch }
    other = nil
    Thread.new { other = piped_commands(fetcher) }.join

    assert_equal [nil, %w[SISMEMBER LMOVE BLMOVE SISMEMBER]], other
  end

  def test_single_queue_fetch_acknowledges_and_takes_the_oldest_job
    fetcher = single_queue
    key, = warm(fetcher, 1)
    done = unit_in_flight(fetcher, "done", "only")
    other = unit_in_flight(fetcher, "other", "only")
    push("only", "j2", "j1")
    unit = nil
    pool = recording_pool { unit = assert_roundtrips(1) { fetcher.fetch(0, ack: done.key) } }

    assert_equal ["only", "j2", fetcher, key], [unit.queue, unit.raw, unit.fetcher, unit.key]
    assert_equal %w[j2 other], inflight
    assert_equal %w[j1], queue("only")
    assert_equal [[:pipelined], [:pipe, "DEL", done.key], [:pipe, "SISMEMBER", config.key("paused"), "only"],
      [:pipe, "LMOVE", config.key("queue", "only"), key, "RIGHT", "LEFT"]], pool.calls
    assert_equal [done.key], free(fetcher)
    assert_includes registered, other.key
  end

  def test_single_queue_fetch_registers_a_new_key_first
    fetcher = single_queue
    push("only", "j1")
    unit = nil
    pool = recording_pool { unit = fetcher.fetch }

    assert_equal "j1", unit.raw
    assert_equal [[:pipelined], [:pipe, "SADD", set, unit.key], [:pipe, "SISMEMBER", config.key("paused"), "only"],
      [:pipe, "LMOVE", config.key("queue", "only"), unit.key, "RIGHT", "LEFT"]], pool.calls
    assert_equal [unit.key], registered
  end

  def test_single_queue_fetch_acknowledges_even_when_no_job_is_waiting
    fetcher = single_queue
    done = unit_in_flight(fetcher, "done", "only")
    key, = warm(fetcher, 1)

    recording_pool { assert_nil fetcher.fetch(0, ack: done.key) }

    assert_empty inflight
    assert_equal [key, done.key], free(fetcher), "the unfilled key is free again too"
  end

  def test_single_queue_job_from_a_queue_just_paused_is_handed_back
    fetcher = single_queue
    key, = warm(fetcher, 1)
    push("only", "j2", "j1")
    redis("SADD", config.key("paused"), "only")

    assert_nil fetcher.fetch
    assert_empty inflight
    assert_equal %w[j1 j2], queue("only"), "back where it was"
    assert_equal [key], free(fetcher)
  end

  def test_single_queue_known_to_be_paused_uses_the_script
    fetcher = single_queue
    fetcher.paused = %w[only]
    fetcher.define_singleton_method(:sleep) { |_s| nil }
    warm(fetcher, 1)
    done = unit_in_flight(fetcher, "done", "only")
    pool = recording_pool { assert_nil fetcher.fetch(0, ack: done.key) }

    assert_equal [:evalsha], pool.calls.map(&:first)
    assert_empty inflight
  end

  # -- batches -------------------------------------------------------------------

  # Pretends +n+ other workers are mid-fetch, waiting for a job too.
  def others_waiting(fetcher, n) = fetcher.instance_variable_set(:@wanting, n)

  def test_one_round_trip_takes_a_job_for_each_waiting_worker
    keys = warm(@fetcher, 4)
    push("high", "h1", "h2", "h3")
    push("low", "l1", "l2")
    others_waiting(@fetcher, 3)
    pool = recording_pool { assert_equal "h1", assert_roundtrips(1) { @fetcher.fetch }.raw }

    assert_equal [:evalsha], pool.calls.map(&:first)
    assert_equal 4, pool.calls.first.last.first
    assert_equal keys.drop(1), @fetcher.held
    assert_equal %w[h1 h2 h3 l1], inflight
    assert_equal %w[l2], queue("low")
    pool = recording_pool do
      assert_equal [["high", "h2", keys[1]], ["high", "h3", keys[2]], ["low", "l1", keys[3]]],
        assert_roundtrips(0) { Array.new(3) { @fetcher.fetch.then { |u| [u.queue, u.raw, u.key] } } }
    end

    assert_empty pool.calls, "handed out without a round trip"
  end

  def test_a_batch_never_exceeds_fetch_batch
    config.fetch_batch = 2
    push("high", "h1", "h2", "h3")
    others_waiting(@fetcher, 5)
    @fetcher.fetch

    assert_equal 1, @fetcher.held.size
    assert_equal %w[h3], queue("high")
  end

  def test_a_short_batch_frees_the_keys_it_did_not_fill
    keys = warm(@fetcher, 3)
    push("high", "h1")
    others_waiting(@fetcher, 2)

    assert_equal keys.first, @fetcher.fetch.key
    assert_equal keys.drop(1), free
  end

  def test_acknowledgements_wait_for_the_next_round_trip
    push("high", "h1", "h2")
    a = unit_in_flight(@fetcher, "a")
    b = unit_in_flight(@fetcher, "b")
    others_waiting(@fetcher, 1)
    first = @fetcher.fetch(0, ack: a.key)
    others_waiting(@fetcher, 0)
    @fetcher.fetch(0, ack: b.key)

    assert_equal %w[b h1 h2], inflight
    assert_equal [a.key, b.key], @fetcher.held, "a free, b waiting"
    push("high", "h3")

    assert_equal a.key, @fetcher.fetch(0, ack: first.key).key, "filled again"
    assert_equal %w[h2 h3], inflight
    assert_equal [b.key, first.key], @fetcher.held
  end

  def buffer = @fetcher.instance_variable_get(:@buffer)

  def acks = @fetcher.instance_variable_get(:@acks)

  # Buffers a job fetched for another worker; returns its unit.
  def fetched_for_others(raw) = unit_in_flight(@fetcher, raw).tap { |unit| buffer << [unit, 0] }

  def queued_for_acker
    acker = @fetcher.acker
    Array.new(acker.size) { acker.pop }
  end

  def test_the_acker_queue_is_the_fetchers_own_until_the_launcher_sets_it
    assert_instance_of Thread::Queue, @fetcher.acker
    refute_same @fetcher.acker, Robin::Fetcher.new(@capsule, "me").acker
  end

  def test_a_worker_taking_a_job_fetched_for_it_wakes_the_acker_once
    fetched_for_others("x")
    fetched_for_others("y")
    pool = recording_pool do
      @fetcher.fetch(0, ack: "a")
      @fetcher.fetch(0, ack: "b")
    end

    assert_empty pool.calls
    assert_equal %w[a b], acks
    assert_equal [@fetcher], queued_for_acker
  end

  def test_a_worker_taking_a_job_with_nothing_to_acknowledge_leaves_the_acker_be
    fetched_for_others("x")
    @fetcher.fetch

    assert_empty queued_for_acker
  end

  def test_acknowledgements_that_go_with_a_round_trip_leave_the_acker_be
    push("high", "h1")
    @fetcher.fetch(0, ack: "a")

    assert_empty acks
    assert_empty queued_for_acker
  end

  def test_a_failed_round_trip_wakes_the_acker
    warm(@fetcher, 1)
    boom = ->(kind, _args) { raise Robin::Redis::ConnectionError, "down" if kind == :evalsha }
    assert_raises(Robin::Redis::ConnectionError) { recording_pool(boom) { @fetcher.fetch(0, ack: "a") } }

    assert_equal %w[a], acks
    assert_equal [@fetcher], queued_for_acker
  end

  def test_a_failed_round_trip_with_nothing_to_acknowledge_leaves_the_acker_be
    warm(@fetcher, 1)
    boom = ->(kind, _args) { raise Robin::Redis::ConnectionError, "down" if kind == :evalsha }
    assert_raises(Robin::Redis::ConnectionError) { recording_pool(boom) { @fetcher.fetch } }

    assert_empty queued_for_acker
  end

  def test_send_acks_deletes_the_waiting_keys_and_frees_them
    a = unit_in_flight(@fetcher, "a")
    b = unit_in_flight(@fetcher, "b")
    fetched_for_others("x")
    @fetcher.fetch(0, ack: a.key)
    acks << b.key
    queued_for_acker
    held = nil
    spy = lambda do |_kind, _args|
      held = @fetcher.held
      :forward
    end
    pool = recording_pool(spy) { assert_roundtrips(1) { @fetcher.send_acks } }

    assert_equal [[:call, "DEL", a.key, b.key]], pool.calls
    assert_equal [a.key, b.key], held, "held while being sent"
    assert_equal %w[x], inflight
    assert_empty acks
    assert_equal [a.key, b.key], free
    assert_empty @fetcher.instance_variable_get(:@sending)
    fetched_for_others("y")
    @fetcher.fetch(0, ack: "c")

    assert_equal [@fetcher], queued_for_acker, "woken again"
  end

  def test_send_acks_with_nothing_waiting_sends_nothing
    fetched_for_others("x")
    fetched_for_others("y")
    @fetcher.fetch(0, ack: "a")
    @fetcher.fetch
    acks.clear # a round trip took them
    pool = recording_pool { @fetcher.send_acks }

    assert_empty pool.calls
    queued_for_acker
    fetched_for_others("z")
    acks << "b"
    @fetcher.fetch

    assert_equal [@fetcher], queued_for_acker, "woken again"
  end

  def test_acknowledgements_that_failed_to_send_wait_again
    acks.push("a", "b")
    boom = ->(kind, _args) { raise Robin::Redis::ConnectionError, "down" if kind == :call }
    assert_raises(Robin::Redis::ConnectionError) { recording_pool(boom) { @fetcher.send_acks } }

    assert_equal %w[a b], acks
    assert_empty @fetcher.instance_variable_get(:@sending)
    assert_empty free
    assert_empty queued_for_acker, "until a worker leaves more waiting"
  end

  # A failed round trip may have filled its keys without the reply getting
  # here: they're let go of (the sweep puts back what reached them).
  def test_a_failed_round_trip_keeps_its_acknowledgements_and_drops_its_keys
    a = unit_in_flight(@fetcher, "a")
    b = unit_in_flight(@fetcher, "b")
    dropped, = warm(@fetcher, 1)
    boom = ->(kind, _args) { raise Robin::Redis::ConnectionError, "down" if kind == :evalsha }
    assert_raises(Robin::Redis::ConnectionError) { recording_pool(boom) { @fetcher.fetch(0, ack: a.key) } }

    assert_equal [a.key], @fetcher.held
    key, = warm(@fetcher, 1)

    recording_pool(unblocked) { assert_nil @fetcher.fetch(0, ack: b.key) }

    assert_empty inflight
    assert_equal [key, a.key, b.key], @fetcher.held
    assert_includes registered, dropped, "for the sweep to look into"
  end

  def test_keys_being_acknowledged_or_filled_count_as_held
    key, = warm(@fetcher, 1)
    seen = nil
    spy = lambda do |kind, _args|
      seen ||= @fetcher.held if kind == :evalsha
      idle.call(kind, nil)
    end
    recording_pool(spy) { @fetcher.fetch(0, ack: "a") }

    assert_equal [key, "a"], seen
  end

  # Until the round trip is over, every key it filled is held, also while
  # its jobs are being sorted out.
  def test_keys_stay_held_until_their_jobs_are_buffered
    keys = warm(@fetcher, 3)
    push("high", "h1", "h2", "h3")
    others_waiting(@fetcher, 2)
    seen = []
    real = Robin::Fetcher::UnitOfWork.method(:new)
    fetcher = @fetcher

    stub_method(Robin::Fetcher::UnitOfWork, :new, ->(*args) { (seen << fetcher.held.sort) && real.call(*args) }) do
      assert_equal "h1", @fetcher.fetch.raw
    end

    assert_equal [keys.sort] * 3, seen
  end

  def test_a_worker_takes_a_job_fetched_for_it_instead_of_blocking
    @fetcher.instance_variable_get(:@buffer) << [Robin::Fetcher::UnitOfWork.new("low", "l1", @fetcher, "k"), 0]
    pool = recording_pool { assert_equal "l1", @fetcher.send(:wait, 0, %w[high low]).raw }

    assert_empty pool.calls
  end

  def test_release_hands_back_fetched_jobs_in_order_and_acknowledges
    push("high", "h1", "h2", "h3")
    push("low", "l1")
    done = unit_in_flight(@fetcher, "done")
    others_waiting(@fetcher, 9)
    first = @fetcher.fetch
    second = @fetcher.fetch(0, ack: done.key)
    h3, l1 = @fetcher.instance_variable_get(:@buffer).map { |unit, _at| unit.key }
    pool = recording_pool { assert_roundtrips(1) { @fetcher.release } }

    assert_equal %w[h1 h2], inflight, "only the jobs handed out"
    assert_equal %w[h3], queue("high")
    assert_equal %w[l1], queue("low")
    assert_equal [[:multi], [:tx, "LMOVE", l1, config.key("queue", "low"), "RIGHT", "RIGHT"],
      [:tx, "LMOVE", h3, config.key("queue", "high"), "RIGHT", "RIGHT"], [:tx, "DEL", done.key]], pool.calls
    assert_equal [h3, l1, done.key], @fetcher.held.last(3)
    assert_equal (registered - [first.key, second.key]).sort, @fetcher.held.sort, "the rest are free"
    assert_roundtrips(0) { @fetcher.release }
  end

  def test_release_with_only_acknowledgements_or_only_jobs_to_hand_back
    done = unit_in_flight(@fetcher, "done")
    @fetcher.instance_variable_get(:@acks) << done.key
    pool = recording_pool { @fetcher.release }

    assert_equal [[:multi], [:tx, "DEL", done.key]], pool.calls
    push("high", "h1", "h2")
    others_waiting(@fetcher, 9)
    @fetcher.fetch
    pool = recording_pool { @fetcher.release }

    assert_equal [:multi, :tx], pool.calls.map(&:first)
  end

  # What the heartbeat does with each capsule's fetcher (see
  # Launcher#hand_back_stale).
  def refresh(paused)
    units = @fetcher.stale(paused)
    config.redis { |c| c.multi { |tx| @fetcher.hand_back(tx, units) } } unless units.empty?
    @fetcher.freed(units)
  end

  def test_stale
    assert_roundtrips(0) { assert_empty @fetcher.stale(%w[low x]) }
    assert_equal %w[low x], @fetcher.paused
  end

  def test_refresh_hands_back_jobs_from_newly_paused_queues
    push("high", "h1", "h2")
    push("low", "l1", "l2")
    others_waiting(@fetcher, 9)
    @fetcher.fetch
    buffered = @fetcher.instance_variable_get(:@buffer).map { |unit, _at| unit.key }
    refresh(%w[low])

    assert_equal [buffered.first], @fetcher.instance_variable_get(:@buffer).map { |unit, _at| unit.key }
    assert_equal %w[l2 l1], queue("low")
    assert_equal %w[h1 h2], inflight
    assert_includes free, buffered.last
  end

  def test_refresh_hands_back_jobs_no_worker_took_in_time
    push("high", "h1", "h2", "h3")
    others_waiting(@fetcher, 9)
    @fetcher.fetch
    buffer = @fetcher.instance_variable_get(:@buffer)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    buffer[0][1] = now - Robin::Fetcher::STALE - 1
    buffer[1][1] = now - Robin::Fetcher::STALE + 30
    refresh([])

    assert_equal %w[h3], @fetcher.instance_variable_get(:@buffer).map { |unit, _at| unit.raw }
    assert_equal %w[h2], queue("high")
  end

  def test_single_queue_batches_of_small_jobs_use_the_script
    fetcher = single_queue
    keys = warm(fetcher, 4)
    push("only", "j1", "j2", "j3")
    others_waiting(fetcher, 3)
    pool = recording_pool { assert_equal "j1", fetcher.fetch.raw }

    assert_equal [[:evalsha, Robin::Scripts::FETCH, [config.key("paused"), *keys, config.key("queue", "only")], [4, "only"]]], pool.calls
    assert_equal [keys[3], keys[1], keys[2]], fetcher.held, "the unfilled key, then the jobs for other workers"
  end

  # The script copies jobs into Lua and out: once they're large, a batch
  # costs Redis less as a command per job.
  def test_single_queue_batches_of_large_jobs_use_plain_commands
    fetcher = single_queue
    large = "x" * (Robin::Fetcher::LARGE + 1)
    limit = "y" * Robin::Fetcher::LARGE
    push("only", large)
    fetcher.fetch # a single job: large, so batches will be too

    keys = warm(fetcher, 3)
    done = unit_in_flight(fetcher, "done", "only")
    push("only", large, limit)
    others_waiting(fetcher, 2)
    pool = recording_pool { assert_equal large, fetcher.fetch(0, ack: done.key).raw }
    source = config.key("queue", "only")

    assert_equal [[:pipelined], [:pipe, "DEL", done.key], [:pipe, "SISMEMBER", config.key("paused"), "only"],
      *keys.map { |key| [:pipe, "LMOVE", source, key, "RIGHT", "LEFT"] }], pool.calls
    assert_equal [keys[2], done.key, keys[1]], fetcher.held, "the free keys, then the job for another worker"
    assert_equal limit, fetcher.fetch.raw
    push("only", limit, limit)
    others_waiting(fetcher, 1)
    pool = recording_pool { fetcher.fetch }

    assert_equal :pipelined, pool.calls.first.first, "still large"
    fetcher.fetch # the buffered one
    warm(fetcher, 2)
    push("only", "a", "b")
    others_waiting(fetcher, 1)
    pool = recording_pool { assert_equal "a", fetcher.fetch.raw }

    assert_equal [:evalsha], pool.calls.map(&:first), "LARGE bytes a job isn't large"
  end

  def test_a_batch_handed_back_does_not_judge_job_sizes
    fetcher = single_queue
    warm(fetcher, 2)
    fetcher.instance_variable_set(:@large, true)
    push("only", "a", "b")
    redis("SADD", config.key("paused"), "only")
    others_waiting(fetcher, 1)

    assert_nil fetcher.fetch(0)
    assert fetcher.instance_variable_get(:@large)
  end

  def test_concurrent_workers_get_every_job_exactly_once
    config.fetch_timeout = 0.05
    jobs = Array.new(400) { |i| "j#{i}" }
    jobs.each_slice(100) { |slice| push("low", *slice) }
    workers = Array.new(8) do |slot|
      Thread.new do
        Thread.current.report_on_exception = false
        mine = []
        last = nil
        while (unit = @fetcher.fetch(slot, ack: last&.key)) # also acknowledges the last one
          mine << unit.raw
          last = unit
        end
        mine
      rescue => e
        e
      end
    end
    taken = workers.map { |w| w.join(5)&.value || w.kill && :hung }

    assert_equal jobs.sort, taken.flatten.sort
    @fetcher.release

    assert_empty inflight
    assert_equal registered, @fetcher.held.sort, "every key free, and registered"
  end

  def test_handed_back_jobs_keep_their_place_in_line
    push("high", "h1", "h2", "h3", "h4")
    others_waiting(@fetcher, 9)
    @fetcher.fetch
    @fetcher.release

    assert_equal %w[h4 h3 h2], queue("high")
    assert_equal %w[h2 h3 h4], Array.new(3) { @fetcher.fetch.raw }
  end

  # -- units of work ---------------------------------------------------------------

  def test_unit_acknowledge_deletes_and_unregisters_its_key
    first = unit_in_flight(@fetcher, "a", "high")
    second = unit_in_flight(@fetcher, "b", "high")

    assert_equal [1, 1], first.acknowledge
    assert_equal %w[b], inflight
    assert_equal [second.key], registered
    rec = recording { |c| second.acknowledge(c) }

    assert_equal [[:call, "DEL", second.key], [:call, "SREM", set, second.key]], rec.calls
    assert_empty inflight
    assert_empty registered
    assert_empty free, "never used again"
  end

  def test_unit_requeue_moves_the_job_back_and_frees_its_key
    push("high", "newer")
    unit = unit_in_flight(@fetcher, "x", "high")
    pool = recording_pool { assert_nil unit.requeue }

    assert_empty inflight
    assert_equal %w[newer x], queue("high")
    assert_equal [[:multi], [:tx, "LMOVE", unit.key, config.key("queue", "high"), "RIGHT", "RIGHT"]], pool.calls
    assert_equal [unit.key], free
    assert_equal "x", @fetcher.fetch.raw
  end

  def test_acknowledge_deletes_keys_in_one_command_and_frees_them
    a = unit_in_flight(@fetcher, "a")
    b = unit_in_flight(@fetcher, "b")
    rec = recording { |c| @fetcher.acknowledge(c, [a.key, b.key]) }

    assert_equal [[:call, "DEL", a.key, b.key]], rec.calls
    assert_empty inflight
    assert_equal [a.key, b.key], free
    rec = recording { |c| assert_nil @fetcher.acknowledge(c, []) }

    assert_empty rec.calls
  end

  def test_put_back_returns_nil_and_frees_keys
    unit = unit_in_flight(@fetcher, "x", "high")

    config.redis { |c| assert_nil @fetcher.put_back(c, [unit]) }
    rec = recording { |c| assert_nil @fetcher.put_back(c, []) }

    assert_equal %w[x], queue("high")
    assert_empty rec.calls
    assert_equal [unit.key], free
  end

  # -- the sweep's view ------------------------------------------------------------

  def test_held_lists_free_filling_buffered_and_acknowledging_keys
    free(@fetcher).push("f")
    @fetcher.instance_variable_get(:@filling)[:t] = %w[g h]
    @fetcher.instance_variable_get(:@buffer) << [Robin::Fetcher::UnitOfWork.new("low", "x", @fetcher, "b"), 0]
    @fetcher.instance_variable_get(:@acks) << "a"
    @fetcher.instance_variable_get(:@sending)[:t] = %w[s]

    assert_equal %w[f g h b a s], @fetcher.held
  end

  def test_forget_refuses_held_keys
    free(@fetcher).push("f")
    @fetcher.instance_variable_get(:@filling)[:t] = %w[g]
    @fetcher.instance_variable_get(:@buffer) << [Robin::Fetcher::UnitOfWork.new("low", "x", @fetcher, "b"), 0]
    @fetcher.instance_variable_get(:@acks) << "a"
    @fetcher.instance_variable_get(:@sending)[:t] = %w[s]

    %w[f g b a s].each { |key| assert_false @fetcher.forget(key), key }
    assert_empty @fetcher.instance_variable_get(:@lost)
    assert_true @fetcher.forget("other")
    assert_equal({"other" => true}, @fetcher.instance_variable_get(:@lost))
  end

  # A key the sweep took over (and unregistered) is never filled again,
  # even if a worker that still had it acknowledges it.
  def test_a_forgotten_key_is_not_used_again
    assert_true @fetcher.forget("k")
    config.redis { |c| @fetcher.acknowledge(c, %w[j k l]) }

    assert_equal %w[j l], free
    assert_empty @fetcher.instance_variable_get(:@lost), "once is enough"
    config.redis { |c| @fetcher.acknowledge(c, %w[k]) }

    assert_equal %w[j l k], free
  end

  def test_retire_queues_deletion_and_unregistration
    rec = recording { |c| assert_equal 0, @fetcher.retire(c, "k") }

    assert_equal [[:call, "DEL", "k"], [:call, "SREM", set, "k"]], rec.calls
  end

  # -- the fetcher's state is shared by its capsule's workers ------------------

  def buffered(fetcher, *raws)
    raws.each { |raw| fetcher.instance_variable_get(:@buffer) << [Robin::Fetcher::UnitOfWork.new("low", raw, fetcher, "k#{raw}"), 0] }
  end

  # Runs the block on another thread while this one holds the fetcher's
  # lock, asserts it waits for it, and returns its value.
  def assert_waits_for_lock(fetcher = @fetcher, &)
    worker = fetcher.instance_variable_get(:@lock).synchronize do
      thread = Thread.new(&)

      refute thread.join(0.05), "didn't wait for the lock"
      thread
    end
    worker.value
  end

  def test_shared_state_is_only_touched_under_the_lock
    buffered(@fetcher, "a", "b", "c", "d")

    assert_equal "a", assert_waits_for_lock { @fetcher.fetch }.raw
    assert_equal "b", assert_waits_for_lock { @fetcher.send(:wait, 0, %w[low]) }.raw
    assert_equal %w[kc kd], assert_waits_for_lock { @fetcher.held }
    assert assert_waits_for_lock { @fetcher.forget("x") }
    stale = assert_waits_for_lock { @fetcher.stale([]) }
    assert_waits_for_lock { @fetcher.freed(stale) }
    assert_waits_for_lock { @fetcher.release }
    assert_waits_for_lock { config.redis { |c| @fetcher.acknowledge(c, %w[y]) } }
    assert_waits_for_lock { config.redis { |c| @fetcher.put_back(c, []) } }
    assert_equal %w[kc kd y], @fetcher.held
  end

  # Runs the block on another thread while this one holds the fetcher's
  # lock, and asserts the fetcher's buffer and acknowledgements are left
  # alone until it lets go.
  def assert_leaves_state_alone_until_unlocked(&)
    buffer = @fetcher.instance_variable_get(:@buffer).dup
    acks = @fetcher.instance_variable_get(:@acks).dup
    worker = @fetcher.instance_variable_get(:@lock).synchronize do
      thread = Thread.new(&)
      thread.join(0.05)

      assert_equal [buffer, acks], [@fetcher.instance_variable_get(:@buffer), @fetcher.instance_variable_get(:@acks)]
      thread
    end
    worker.join
  end

  def test_refresh_and_release_take_from_the_buffer_under_the_lock
    buffered(@fetcher, "a", "b")
    @fetcher.instance_variable_get(:@acks) << "done"
    assert_leaves_state_alone_until_unlocked { refresh([]) }

    assert_empty @fetcher.instance_variable_get(:@buffer)
    buffered(@fetcher, "c")
    assert_leaves_state_alone_until_unlocked { @fetcher.release }

    assert_empty @fetcher.instance_variable_get(:@buffer)
    assert_empty @fetcher.instance_variable_get(:@acks)
  end

  # Runs send_acks on another thread, holding the DEL until this thread
  # holds the fetcher's lock; asserts it then waits for the lock before
  # settling, with +acks+ and the free keys left alone. +fail+ makes the
  # DEL fail. Returns what send_acks returned or raised.
  def assert_send_acks_settles_under_the_lock(fail: false)
    reached = Thread::Queue.new
    go = Thread::Queue.new
    held = lambda do |_kind, _args|
      reached << true
      go.pop
      raise Robin::Redis::ConnectionError, "down" if fail

      :forward
    end
    result = nil
    recording_pool(held) do
      thread = Thread.new do
        @fetcher.send_acks
      rescue => e
        e
      end
      reached.pop
      before = [acks.dup, free.dup]
      @fetcher.instance_variable_get(:@lock).synchronize do
        go << true

        refute thread.join(0.05), "didn't wait for the lock"
        assert_equal before, [acks, free]
      end
      result = thread.value
    end
    result
  end

  def test_send_acks_takes_acknowledgements_under_the_lock
    acks << "a"
    assert_leaves_state_alone_until_unlocked { @fetcher.send_acks }

    assert_empty acks
  end

  def test_send_acks_settles_under_the_lock
    acks << "a"

    assert_send_acks_settles_under_the_lock

    assert_equal %w[a], free
    acks << "b"

    assert_equal "down", assert_send_acks_settles_under_the_lock(fail: true).message
    assert_equal %w[b], acks
  end

  def test_a_round_trip_files_its_jobs_under_the_lock
    push("high", "h1", "h2")
    warm(@fetcher, 2)
    others_waiting(@fetcher, 1)
    lock = @fetcher.instance_variable_get(:@lock)
    in_trip = Thread::Queue.new
    go = Thread::Queue.new
    responder = lambda do |kind, _args|
      (in_trip << true) && go.pop if kind == :evalsha
      :forward
    end
    recording_pool(responder) do
      worker = Thread.new { @fetcher.fetch }
      in_trip.pop
      lock.synchronize do
        go << true

        refute worker.join(0.05), "filed its jobs without the lock"
      end

      assert_equal "h1", worker.value.raw
    end
    assert_equal 1, @fetcher.held.size
  end

  def test_a_blocking_round_trip_settles_its_key_under_the_lock
    warm(@fetcher, 1)
    lock = @fetcher.instance_variable_get(:@lock)
    in_trip = Thread::Queue.new
    go = Thread::Queue.new
    responder = lambda do |kind, _args|
      return [] if kind == :evalsha

      (in_trip << true) && go.pop if kind == :pipelined
      [nil]
    end
    recording_pool(responder) do
      worker = Thread.new { @fetcher.fetch(0) }
      in_trip.pop
      lock.synchronize do
        go << true

        refute worker.join(0.05), "settled its key without the lock"
      end

      assert_nil worker.value
    end
    assert_equal 1, @fetcher.held.size
  end

  def test_a_round_trip_leaves_other_workers_acknowledgements_alone
    @fetcher.instance_variable_get(:@sending)[:other] = %w[x]
    warm(@fetcher, 1)
    recording_pool(idle) { @fetcher.fetch(0, ack: "a") }

    assert_includes @fetcher.held, "x"
  end
end
