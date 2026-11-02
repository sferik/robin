# frozen_string_literal: true

# A standalone dashboard over the demo data written by seed.rb:
#
#   ruby examples/web_demo/seed.rb
#   rackup examples/web_demo/config.ru -p 9292
#
# then open http://localhost:9292/robin
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "robin/web"

Robin.configure do |config|
  config.redis = {url: ENV.fetch("ROBIN_DEMO_REDIS_URL", "redis://127.0.0.1:6379/15")}
  config.key_prefix = ENV.fetch("ROBIN_DEMO_PREFIX", "robindemo:")
end

Robin::Web.title = ENV.fetch("ROBIN_DEMO_TITLE", "Robin")

if ENV["ROBIN_DEMO_CLUSTERS"]
  eu = Robin::Config.new
  eu.redis = {url: ENV.fetch("ROBIN_DEMO_REDIS_URL", "redis://127.0.0.1:6379/15")}
  eu.key_prefix = "robindemo-eu:"
  Robin::Web.clusters = {"us-east" => Robin.config, "eu-west" => eu}
end

Robin::Web.read_only = true if ENV["ROBIN_DEMO_READ_ONLY"]

# A page of the app's own (see Robin::Web::Extension).
class BillingPage < Robin::Web::Extension
  slug "billing"
  title "Billing"

  def blocks(request)
    waiting = Robin::Queue.new("default", config: request.config).size
    [
      {type: "stats", items: [{label: "Invoices waiting", value: waiting}, {label: "Sent today", value: 1_284}, {label: "Overdue", value: 3}]},
      {type: "heading", text: "Overdue invoices"},
      {type: "table", columns: ["Customer", "Invoice", "Total", "Days late"],
       rows: [["Acme Corp", "INV-1042", "$1,250.00", 12], ["Globex", "INV-1057", "$89.00", 4], ["Initech", "INV-1063", "$420.50", 2]]},
      {type: "text", text: "Invoices go out at 6am UTC. Sending now pushes one job per customer."},
      {type: "actions", items: [{label: "Send invoices now", action: "send"},
        {label: "Write off overdue", action: "write_off", confirm: "Write off 3 overdue invoices?", danger: true}]}
    ]
  end

  action("send") { |_request| "Queued 1,284 invoices" }
  action("write_off") { |_request| "Wrote off 3 invoices" }
end

Robin::Web.register(BillingPage)

map "/robin" do
  run Robin::Web
end

map "/" do
  run ->(_env) { [302, {"location" => "/robin"}, []] }
end
