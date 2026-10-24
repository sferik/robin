# frozen_string_literal: true

# The demo app: Robin's configuration and a handful of jobs that exercise
# its features. Everything else (bin/work, bin/web, bin/seed, bin/load)
# loads this file.

require "robin"
require "timeout"

module Demo
  # Every key the demo writes starts with this, so bin/reset can delete
  # exactly the demo's data and nothing else in the same Redis.
  PREFIX = "robin-demo:"
  REDIS_URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

  def self.pause(seconds) = sleep(seconds * Float(ENV.fetch("DEMO_SPEED", "1")))
end

Robin.configure do |config|
  config.redis = {url: Demo::REDIS_URL}
  config.key_prefix = Demo::PREFIX
  config.tag = "demo"
  # A fixed, public key: fine for a demo, never for real data.
  config.encryption_keys = {1 => "de30" * 16} # 64 hex characters
  config.logger.level = ENV.fetch("LOG_LEVEL", "info")
  # Failed jobs come back in seconds rather than minutes, so the retry
  # set keeps changing while you watch.
  config.retry_backoff = ->(failures, _ex, _payload, custom) { custom || (5 * failures) + rand(5) }
end

Robin.configure_server do |config|
  config.periodic do |cron|
    cron.register "* * * * *", "DigestEmail", args: ["every-minute"], description: "Sends the minutely digest"
    cron.register "*/5 * * * *", "NightlyReport", queue: "reports", description: "Pretends it's night every 5 minutes"
    cron.register "0 3 * * *", "PruneSessions", description: "Really is nightly"
  end
end

# -- plain jobs ---------------------------------------------------------------

class WelcomeEmail
  include Robin::Job

  robin_options queue: "mailers", tags: ["email"]

  def perform(user_id)
    logger.info("welcoming user #{user_id}")
    Demo.pause(rand(0.05..0.3))
  end
end

class DigestEmail
  include Robin::Job

  robin_options queue: "mailers", tags: ["email"]

  def perform(kind) = Demo.pause(0.2)
end

class PruneSessions
  include Robin::Job

  robin_options queue: "low"

  def perform = Demo.pause(0.5)
end

# Reports progress, which the dashboard's Busy page shows live.
class ResizeImage
  include Robin::Job

  robin_options queue: "media", retry: 5, tags: ["images"]

  def perform(image_id, width)
    steps = 10
    steps.times do |i|
      break if cancelled?

      Demo.pause(rand(0.1..0.4))
      progress!((i + 1) * 100.0 / steps, "#{width}px: step #{i + 1} of #{steps}")
    end
  end
end

# Fails about a third of the time, with a few different errors, so the
# retry set fills up and drains as retries succeed.
class FlakyWebhook
  include Robin::Job

  robin_options queue: "default", retry: 4, backtrace: 10, tags: ["webhooks"]

  class RemoteError < StandardError; end

  ERRORS = [
    [::Timeout::Error, "execution expired"],
    [RemoteError, "502 Bad Gateway from hooks.example.com"],
    [Errno::ECONNREFUSED, "connect(2) for hooks.example.com:443"]
  ].freeze

  def perform(endpoint, event)
    Demo.pause(rand(0.05..0.2))
    error, message = ERRORS.sample
    raise error, message if rand < 0.35
  end
end

# Always fails and never retries: straight to the dead set. (retry: false
# would drop it instead.)
class ImportLegacyCsv
  include Robin::Job

  robin_options queue: "low", retry: 0, tags: ["imports"]

  def perform(path) = raise(ArgumentError, "#{path}: unknown column \"fax_number\" on line #{rand(2..400)}")
end

# Fails once, retries, then dies after its last retry.
class SyncCrm
  include Robin::Job

  robin_options queue: "default", retry: 1

  def perform(account_id) = raise(IOError, "CRM session expired for account #{account_id}")
end

# Pure Ruby computation: a few of these at once make the dashboard's GVL
# column climb, since only one thread runs Ruby code at a time.
class CrunchNumbers
  include Robin::Job

  robin_options queue: "reports"

  def perform(iterations)
    x = 0
    iterations.times { |i| x += i * i % 7 }
    x
  end
end

class NightlyReport
  include Robin::Job

  robin_options queue: "reports"

  def perform = CrunchNumbers.new.perform(2_000_000)
end

# Ledger entries run on the "serial" capsule's single thread, one at a time.
class PostLedgerEntry
  include Robin::Job

  robin_options queue: "ledger"

  def perform(entry_id, cents) = Demo.pause(0.1)
end

# -- features -----------------------------------------------------------------

class RebuildSearchIndex
  include Robin::Job

  robin_options queue: "low", unique_for: 120 # duplicates within 2 minutes are dropped

  def perform(index) = Demo.pause(1)
end

class SyncContact
  include Robin::Job

  robin_options queue: "default", debounce: 10 # runs once, 10s after the last push

  def perform(contact_id) = Demo.pause(0.1)
end

class FlashSale
  include Robin::Job

  robin_options queue: "low", expires_in: 20 # skipped unless it starts within 20s

  def perform(sku) = Demo.pause(0.1)
end

class ChargeCard
  include Robin::Job

  robin_options queue: "critical", encrypt: true, tags: ["payments"] # arguments encrypted at rest

  PAYMENTS = Robin::Limiter.concurrent("payment-gateway", 2, wait_timeout: 1, lock_timeout: 30)

  def perform(customer_id, cents)
    PAYMENTS.within_limit { Demo.pause(rand(0.2..0.6)) }
  end
end

class GeocodeAddress
  include Robin::Job

  robin_options queue: "default"

  GEOCODER = Robin::Limiter.bucket("geocoder", 5, :second, wait_timeout: 0)

  def perform(address) = GEOCODER.within_limit { Demo.pause(0.05) }
end

# Saves its position as it goes; a restart resumes where it stopped.
class ExportOrders
  include Robin::IterableJob

  robin_options queue: "reports"

  def build_enumerator(account_id, count, cursor:)
    array_enumerator((1..count).to_a, cursor: cursor)
  end

  def each_iteration(order_id, _account_id, count)
    Demo.pause(0.05)
    progress!(order_id * 100.0 / count, "order #{order_id} of #{count}")
  end
end

# A batch's rows, and what runs when it finishes.
class ImportRow
  include Robin::Job

  robin_options queue: "default", retry: 2, tags: ["imports"]

  def perform(file, row)
    Demo.pause(rand(0.02..0.1))
    raise ArgumentError, "#{file} row #{row}: email is blank" if row % 97 == 0
  end
end

class ImportCallbacks
  def on_complete(status, options)
    Robin.logger.info("import #{options["file"]} finished: #{status.total} rows, #{status.failures} failed")
  end

  def on_success(status, options)
    WelcomeEmail.perform_async(options["owner_id"])
  end
end

module Demo
  # Starts a batch of ImportRow jobs for +file+.
  def self.import(file, rows, owner_id: 1)
    batch = Robin::Batch.new
    batch.description = "Import #{file} (#{rows} rows)"
    batch.tags = ["imports", "owner:#{owner_id}"]
    batch.on(:complete, ImportCallbacks, "file" => file)
    batch.on(:success, ImportCallbacks, "owner_id" => owner_id)
    batch.jobs { ImportRow.perform_bulk((1..rows).map { |row| [file, row] }) }
  end
end
