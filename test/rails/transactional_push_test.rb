# frozen_string_literal: true

require_relative "helper"

class TransactionalPushTest < RobinTest
  cover "Robin::Rails::TransactionalPush*"

  def queue_items = Robin::Queue.new("default").map(&:args)

  # A transaction left open by a test (never committed nor rolled back).
  def teardown
    Thread.current[Robin::Rails::TransactionalPush::WAITING] = nil
    super
  end

  # A stand-in for ActiveRecord's after_all_transactions_commit: blocks
  # wait while a transaction is open.
  def with_fake_active_record(callbacks: true, &)
    skip "real ActiveRecord is loaded" if defined?(::ActiveRecord)
    install_fake_active_record(callbacks, &)
  end

  # Its transactions: whichever +transaction+ holds is current (ActiveRecord::Base.current_transaction).
  def install_fake_active_record(callbacks, transaction: nil)
    held = []
    ar = Module.new
    ar.define_singleton_method(:after_all_transactions_commit) { |&block| held << block } if callbacks
    if transaction
      base = Class.new
      base.define_singleton_method(:current_transaction) { transaction.first }
      ar.const_set(:Base, base)
    end
    Object.const_set(:ActiveRecord, ar)
    yield held
  ensure
    Object.send(:remove_const, :ActiveRecord) if ar
  end

  Transaction = Struct.new(:open?)

  def with_transactions(&)
    skip "real ActiveRecord is loaded" if defined?(::ActiveRecord)
    current = [Transaction.new(true)]
    install_fake_active_record(true, transaction: current) { |held| yield held, current }
  end

  def push(arg) = Robin::Client.new.push("class" => "T", "args" => [arg])

  def test_jobs_pushed_in_one_transaction_go_together_once_it_commits
    config.push_deferrer = Robin::Rails::TransactionalPush
    with_transactions do |held|
      assert_roundtrips(0) { 3.times { |i| push(i) } }
      assert_equal 1, held.size, "one callback for the transaction"
      assert_roundtrips(1) { held.each(&:call) }
      assert_equal [[0], [1], [2]], queue_items.sort
      assert_nil Thread.current[Robin::Rails::TransactionalPush::WAITING]
    end
  end

  def test_each_transaction_has_its_own_jobs
    config.push_deferrer = Robin::Rails::TransactionalPush
    with_transactions do |held, current|
      push(1)
      current[0] = Transaction.new(true) # the first rolled back (its callback never runs); another began
      push(2)
      push(3)

      assert_equal 2, held.size
      held.last.call

      assert_equal [[2], [3]], queue_items.sort
      push(4) # a later one again

      assert_equal 3, held.size
    end
  end

  def test_a_job_pushed_outside_a_transaction_waits_alone
    config.push_deferrer = Robin::Rails::TransactionalPush
    with_transactions do |held, current|
      current[0] = Transaction.new(false)
      push(1)
      push(2)

      assert_equal 2, held.size
      assert_nil Thread.current[Robin::Rails::TransactionalPush::WAITING]
    end
  end

  def test_a_later_transactions_jobs_survive_an_earlier_callback
    config.push_deferrer = Robin::Rails::TransactionalPush
    with_transactions do |held, current|
      push(1)
      first = held.first
      current[0] = Transaction.new(true)
      push(2)
      first.call

      assert_equal [[1]], queue_items
      push(3)

      assert_equal 2, held.size, "joins the later transaction's"
      held.last.call

      assert_equal [[1], [2], [3]], queue_items.sort
    end
  end

  def test_holds_jobs_until_transactions_commit
    config.push_deferrer = Robin::Rails::TransactionalPush
    with_fake_active_record do |held|
      Robin::Client.new.push("class" => "T", "args" => [1])

      assert_empty queue_items
      assert_equal 1, held.size
      held.each(&:call)

      assert_equal [[1]], queue_items
    end
  end

  def test_pushes_now_without_after_all_transactions_commit
    config.push_deferrer = Robin::Rails::TransactionalPush
    with_fake_active_record(callbacks: false) do
      Robin::Client.new.push("class" => "T", "args" => [1])

      assert_equal [[1]], queue_items
    end
    Robin::Client.new.push("class" => "T", "args" => [2])

    assert_equal [[1], [2]], queue_items
  end

  def test_call_reports_whether_it_took_over
    delivered = []
    with_fake_active_record do |held|
      assert_true Robin::Rails::TransactionalPush.call([]) { delivered << :delivered }
      held.each(&:call)

      assert_equal [:delivered], delivered
    end
    assert_false Robin::Rails::TransactionalPush.call([]) { flunk }
  end
end
