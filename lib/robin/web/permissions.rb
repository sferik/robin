# frozen_string_literal: true

module Robin
  class Web
    # Fine-grained actions passed to Robin::Web.authorize. Everything
    # except :read changes state.
    module Permissions
      ACTIONS = {
        read: "View the dashboard",
        retry: "Retry or enqueue jobs now",
        edit: "Edit job arguments",
        delete: "Delete jobs and clear queues",
        kill: "Move jobs to the dead set",
        pause: "Pause and resume queues and cron jobs",
        cancel: "Cancel jobs",
        process_control: "Quiet, stop or resize processes",
        enqueue: "Run cron jobs now",
        limiters: "Reset and delete rate limiters",
        batches: "Delete batches",
        profiles: "Delete job profiles",
        extensions: "Use actions on extension pages"
      }.freeze

      class << self
        def allowed?(env, action, resource = nil)
          return false if !action.eql?(:read) && Web.read_only

          auth = Web.authorizer
          return true unless auth

          !!auth.call(env, action, resource)
        end

        def for(env)
          ACTIONS.to_h { |action, _| [action.to_s, allowed?(env, action)] }
        end
      end
    end
  end
end
