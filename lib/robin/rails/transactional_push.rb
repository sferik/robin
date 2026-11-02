# frozen_string_literal: true

module Robin
  module Rails
    # A Config#push_deferrer that holds jobs pushed inside Active Record
    # transactions until all of them commit (rolled back transactions drop
    # them), so a job never runs before the data it needs is visible. It
    # needs ActiveRecord.after_all_transactions_commit (Rails 7.2+); without
    # it, jobs are pushed right away.
    #
    # The jobs pushed inside the same transaction wait together and go in
    # one round trip once it commits.
    module TransactionalPush
      # [the transaction, the deliveries waiting on it] for this thread.
      WAITING = :robin_transactional_push

      def self.call(_payloads, &deliver)
        return false unless defined?(::ActiveRecord.after_all_transactions_commit)

        transaction = current_transaction
        waiting = Thread.current[WAITING]
        if transaction && waiting&.first.equal?(transaction)
          waiting.last << deliver
          return true
        end

        deliveries = [deliver]
        Thread.current[WAITING] = [transaction, deliveries] if transaction
        ActiveRecord.after_all_transactions_commit do
          Thread.current[WAITING] = nil if Thread.current[WAITING]&.last.equal?(deliveries)
          Client.together { deliveries.each(&:call) }
        end
        true
      end

      # The innermost open transaction on the primary database, if any.
      # Jobs pushed in it are delivered when the same transactions commit.
      # One rolled back is never current again, so the deliveries left
      # waiting on it are never added to (nor made).
      def self.current_transaction
        return unless defined?(ActiveRecord::Base.current_transaction)

        transaction = ActiveRecord::Base.current_transaction
        transaction if transaction.open?
      end
      private_class_method :current_transaction
    end
  end
end
