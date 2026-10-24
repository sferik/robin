# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/web"
require "robin/web"
require "tmpdir"
require "pathname"

# Extension pages are built inside each test (not at load time), so the
# DSL they use runs under mutation testing too.
module WebExtensionTestPages
  def billing_page
    Class.new(Robin::Web::Extension) do
      def self.name = "BillingPage"

      slug "billing"
      title "Billing desk"

      def blocks(request)
        [{"type" => "stats", "items" => [{"label" => "Waiting", "value" => Robin::Queue.new("invoices", config: request.config).size}]},
          {"type" => "text", "text" => "params=#{request.params.inspect} env=#{request.env["REQUEST_METHOD"]}"}]
      end

      action "send" do |request|
        Robin::Client.new(config: request.config).push("class" => "SendInvoices", "args" => [request.params["batch"]])
        "Sending invoices (#{helper})"
      end

      action :echo do |request|
        request.params.inspect
      end

      action "silent" do |_request|
        :not_a_message
      end

      action "explode" do |_request|
        raise ArgumentError, "no invoices"
      end

      def helper = "helper ran"
    end
  end

  def minimal_page = Class.new(Robin::Web::Extension) { slug "minimal-1_x" }

  def broken_page
    Class.new(Robin::Web::Extension) do
      slug "broken"

      def blocks(_request) = raise("db down")
    end
  end
end

class WebExtensionTest < RobinTest
  include WebTestHelpers
  include WebExtensionTestPages

  cover "Robin::Web::Extension*"
  cover "Robin::Web.register"
  cover "Robin::Web.extensions"

  def setup
    super
    @billing = billing_page
  end

  attr_reader :billing

  def test_dsl
    assert_equal "billing", billing.slug
    assert_equal "Billing desk", billing.title
    assert_equal({"slug" => "billing", "title" => "Billing desk"}, billing.to_h)
    assert_equal "Minimal-1_x", minimal_page.title
    titled = minimal_page.tap { |page| page.title(:Ledger) }

    assert_equal "Ledger", titled.title
    assert_equal %w[send echo silent explode], billing.actions.keys
    assert_empty minimal_page.actions
    assert_empty minimal_page.new.blocks(nil)
    assert_equal "BillingPage", billing.name
    assert_instance_of Proc, billing.actions.fetch("echo")
  end

  def test_slugs_are_validated_and_required
    page = Class.new(Robin::Web::Extension)
    error = assert_raises(ArgumentError) { page.slug }

    assert_equal "#{page} needs a slug", error.message
    ["Bad", "-x", "a b", "", "a/b"].each do |bad|
      error = assert_raises(ArgumentError) { page.slug(bad) }

      assert_equal "extension slugs are lowercase letters, digits, - and _: #{bad.inspect}", error.message
    end
    page.slug(:ok9)

    assert_equal "ok9", page.slug
  end

  def test_run
    request = Robin::Web::Extension::Request.new(config, {"batch" => "b1"}, {})

    assert_equal "Sending invoices (helper ran)", billing.new.run("send", request)
    assert_equal "Done", billing.new.run("silent", request)
    assert_raises(KeyError) { billing.new.run("nope", request) }
    assert_equal [["b1"]], Robin::Queue.new.map(&:args)
  end

  def test_register
    assert_empty Robin::Web.extensions
    assert_same billing, Robin::Web.register(billing)
    Robin::Web.register(minimal = minimal_page)

    assert_equal({"billing" => billing, "minimal-1_x" => minimal}, Robin::Web.extensions)
    replacement = Class.new(Robin::Web::Extension) { slug "billing" }
    Robin::Web.register(replacement)

    assert_same replacement, Robin::Web.extensions.fetch("billing")
    [Object, Robin::Web::Extension.new, "billing"].each do |bad|
      error = assert_raises(ArgumentError) { Robin::Web.register(bad) }

      assert_equal "#{bad.inspect} isn't a Robin::Web::Extension", error.message
    end
    assert_raises(ArgumentError) { Robin::Web.register(Robin::Web::Extension) }
    Robin::Web.reset!

    assert_empty Robin::Web.extensions
  end

  # -- over HTTP ----------------------------------------------------------------

  def test_session_lists_extensions
    Robin::Web.register(billing)
    get "/robin/api/session"

    assert_equal [{"slug" => "billing", "title" => "Billing desk"}], json["extensions"]
  end

  def test_page
    Robin::Web.register(billing)
    Robin::Client.push("class" => "X", "args" => [], "queue" => "invoices")
    get "/robin/api/extensions/billing", {"q" => "1"}

    assert_json_response 200, {
      "slug" => "billing", "title" => "Billing desk",
      "blocks" => [{"type" => "stats", "items" => [{"label" => "Waiting", "value" => 1}]},
        {"type" => "text", "text" => %(params=#{{"q" => "1"}.inspect} env=GET)}],
      "messages" => {}
    }
  end

  def test_unknown_pages_and_actions
    Robin::Web.register(billing)
    get "/robin/api/extensions/nope"

    assert_error 404, %(No dashboard extension "nope")
    post_json "/robin/api/extensions/billing/actions/nope"

    assert_error 404, %(Billing desk has no action "nope")
  end

  def test_action
    Robin::Web.register(billing)
    post_json "/robin/api/extensions/billing/actions/send?batch=b7", {}

    assert_json_response 200, {"message" => "Sending invoices (helper ran)"}
    assert_equal [["b7"]], Robin::Queue.new.map(&:args)
  end

  def test_extensions_only_get_their_own_params
    Robin::Web.register(billing)
    post_json "/robin/api/extensions/billing/actions/echo?cluster=default&x=1&locale=de", {}

    assert_json_response 200, {"message" => {"x" => "1"}.inspect}
    get "/robin/api/extensions/billing", {"cluster" => "default", "q" => "2", "locale" => "de"}

    assert_includes json["blocks"].last["text"], "params=#{{"q" => "2"}.inspect}"
  end

  def test_actions_need_permission
    Robin::Web.register(billing)
    seen = []
    Robin::Web.authorize do |_env, action, resource|
      seen << [action, resource]
      action == :read
    end
    post_json "/robin/api/extensions/billing/actions/send"

    assert_error 403, "You don't have permission to use actions on extension pages"
    assert_includes seen, [:extensions, "extension:billing/send"]
    assert_equal 0, Robin::Queue.new.size
  end

  def test_actions_check_csrf
    Robin::Web.register(billing)
    post "/robin/api/extensions/billing/actions/send", "{}", {"CONTENT_TYPE" => "application/json"}

    assert_equal 403, last_response.status
  end

  def test_failures_are_reported
    errors = []
    config.error_handlers.replace([->(ex, ctx, _cfg) { errors << [ex.message, ctx] }])
    Robin::Web.register(broken_page)
    Robin::Web.register(billing)
    get "/robin/api/extensions/broken"

    assert_error 500, "Broken failed: RuntimeError: db down"
    post_json "/robin/api/extensions/billing/actions/explode"

    assert_error 500, "Billing desk failed: ArgumentError: no invoices"
    assert_equal [["db down", {context: "dashboard extension broken (page)"}],
      ["no invoices", {context: "dashboard extension billing (explode)"}]], errors
  end

  # -- frontend code, data and translations ----------------------------------

  def with_files(files)
    Dir.mktmpdir do |dir|
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), content)
      end
      yield File.realpath(dir)
    end
  end

  def scripted_page(dir)
    Class.new(Robin::Web::Extension) do
      slug "reports"
      title "Reports"
      assets File.join(dir, "assets")
      script Pathname("/app.js")
      stylesheet "app.css"
      translations File.join(dir, "locales")

      data :summary do |request|
        {"since" => request.params["since"], "locale" => request.locale, "late" => helper, "title" => request.t("Reports"), "body" => request.body}
      end

      action("quiet") { |_request| nil }

      def blocks(request) = [{"type" => "heading", "text" => request.t("Reports")}]

      data "broken" do |_request|
        raise "no reports"
      end

      action "save" do |request|
        request.t("Saved {name} in {place}", name: request.body["name"], place: request.locale)
      end

      def helper = 3
    end
  end

  FILES = {
    "assets/app.js" => "export default () => {};", "assets/app.js.gz" => "gz", "assets/app.css" => ".x{}",
    "assets/img/bird.svg" => "<svg/>", "assets/data.bin" => "?", "secret.txt" => "no",
    "locales/de.yml" => "Reports: Berichte\nSaved {name} in {place}: \"{name} in {place} gespeichert\"\nDone: Erledigt\n",
    "locales/pt.yml" => "Reports: Relatórios\n", "locales/fr.yml" => "Other: Autre\n7: 8\n", "locales/README.md" => "x",
    "locales/zh-TW.yml" => "Reports: 報告\n"
  }.freeze

  def test_assets_dsl
    with_files(FILES) do |dir|
      page = scripted_page(dir)

      assert_equal "#{dir}/assets", page.assets
      assert_equal ["app.js", "app.css"], [page.script, page.stylesheet]
      assert_equal "#{dir}/locales", page.translations
      assert_equal({"slug" => "reports", "title" => "Reports", "titles" => {"de" => "Berichte", "pt" => "Relatórios", "zh-TW" => "報告"},
                    "script" => "extensions/reports/app.js", "stylesheet" => "extensions/reports/app.css"}, page.to_h)
      assert_equal "#{dir}/assets/img/bird.svg", page.asset_file("img/bird.svg")
      ["../secret.txt", "img", "missing.js", "", "/etc/passwd", "../assets/app.js/../../secret.txt"].each do |bad|
        assert_nil page.asset_file(bad), bad
      end
      relative = Class.new(Robin::Web::Extension) { slug "rel" }
      Dir.chdir(dir) { relative.assets("assets") }

      assert_equal "#{dir}/assets/app.css", relative.asset_file("app.css")
      assert_nil minimal_page.asset_file("app.js")
      assert_nil minimal_page.asset_file(File.join(dir, "assets/app.js"))
      assert_nil minimal_page.assets
      assert_nil minimal_page.script
      assert_nil minimal_page.stylesheet
      assert_nil minimal_page.translations
    end
  end

  def test_script_and_stylesheet_need_assets
    page = minimal_page
    %i[script stylesheet].each do |setting|
      error = assert_raises(ArgumentError) { page.public_send(setting, "x") }

      assert_equal "#{page} needs `assets dir` before its script or stylesheet", error.message
    end
  end

  def test_messages
    with_files(FILES) do |dir|
      page = scripted_page(dir)

      assert_equal({"Reports" => "Berichte", "Saved {name} in {place}" => "{name} in {place} gespeichert", "Done" => "Erledigt"}, page.messages("de"))
      assert_equal({"Reports" => "Relatórios"}, page.messages("pt-BR"))
      assert_equal({"Reports" => "Relatórios"}, page.messages("pt"))
      assert_equal({"Reports" => "報告"}, page.messages("zh-TW"))
      assert_equal({"Other" => "Autre", "7" => "8"}, page.messages("fr"))
      ["zh", "es", "es-MX", "README", "", nil].each { |none| assert_nil page.messages(none), none.inspect }
      File.write(File.join(dir, "locales/es.yml"), "Reports: Informes\n")

      assert_nil page.messages("es") # read when declared
      assert_nil minimal_page.messages("de")
      relative = minimal_page
      Dir.chdir(dir) { relative.translations("locales") }

      assert_equal "#{dir}/locales", relative.translations
      assert_equal "Informes", relative.messages("es").fetch("Reports")
    end
  end

  def test_translations_must_map_text
    with_files("locales/de.yml" => "- a\n- b\n") do |dir|
      error = assert_raises(ArgumentError) { minimal_page.translations(File.join(dir, "locales")) }

      assert_equal "#{dir}/locales/de.yml must map English text to translations", error.message
    end
  end

  def test_request_t
    with_files(FILES) do |dir|
      page = scripted_page(dir)
      request = Robin::Web::Extension::Request.new(config, {}, {}, "de", {}, page)

      assert_equal "Berichte", request.t("Reports")
      assert_equal "a in b gespeichert", request.t("Saved {name} in {place}", name: "a", place: :b)
      assert_equal "Plain {missing} 1", request.t("Plain {missing} {n}", n: 1)
      assert_equal "Reports", Robin::Web::Extension::Request.new(config, {}, {}, "it", {}, page).t("Reports")
      assert_equal "Reports", Robin::Web::Extension::Request.new(config, {}, {}).t("Reports")
      assert_equal "Erledigt", billing.new.run("silent", request)
    end
  end

  def test_serving_assets
    with_files(FILES) do |dir|
      Robin::Web.register(scripted_page(dir))
      get "/robin/extensions/reports/app.js"

      assert_equal [200, "text/javascript; charset=utf-8", "no-cache"], [last_response.status, last_response["content-type"], last_response["cache-control"]]
      assert_equal "export default () => {};", last_response.body
      get "/robin/extensions/reports/app.js", {}, {"HTTP_ACCEPT_ENCODING" => "gzip"}

      assert_equal ["gz", "gzip"], [last_response.body, last_response["content-encoding"]]
      get "/robin/extensions/reports/img/bird.svg"

      assert_equal [200, "image/svg+xml"], [last_response.status, last_response["content-type"]]
      head "/robin/extensions/reports/app.css"

      assert_equal [200, "", "4"], [last_response.status, last_response.body, last_response["content-length"]]
      ["/robin/extensions/reports/../secret.txt", "/robin/extensions/reports/missing.js", "/robin/extensions/nope/app.js",
        "/robin/extensions/reports", "/robin/extensions/"].each do |path|
        get path

        assert_equal [404, "Not found"], [last_response.status, last_response.body], path
      end
      post "/robin/extensions/reports/app.js"

      assert_equal 405, last_response.status
    end
  end

  def test_assets_need_read_permission
    with_files(FILES) do |dir|
      Robin::Web.register(scripted_page(dir))
      seen = []
      Robin::Web.authorize do |env, action, resource|
        seen << [env.fetch("PATH_INFO"), action, resource]
        false
      end
      get "/robin/extensions/reports/app.js"

      assert_error 403, "You don't have access to this dashboard"
      assert_equal [["/extensions/reports/app.js", :read, "/extensions/reports/app.js"]], seen
    end
  end

  def test_data
    with_files(FILES) do |dir|
      Robin::Web.register(scripted_page(dir))
      get "/robin/api/extensions/reports/data/summary", {"since" => "monday", "locale" => "de", "cluster" => "default"}

      assert_json_response 200, {"since" => "monday", "locale" => "de", "late" => 3, "title" => "Berichte", "body" => {}}
      get "/robin/api/extensions/reports/data/summary"

      assert_equal %w[en Reports], json.values_at("locale", "title")
      get "/robin/api/extensions/reports/data/nope"

      assert_error 404, %(Reports has no data "nope")
      errors = []
      config.error_handlers.replace([->(ex, ctx, _cfg) { errors << [ex.message, ctx] }])
      get "/robin/api/extensions/reports/data/broken"

      assert_error 500, "Reports failed: RuntimeError: no reports"
      assert_equal [["no reports", {context: "dashboard extension reports (broken)"}]], errors
    end
  end

  def test_data_params_leave_out_the_route
    page = Class.new(Robin::Web::Extension) do
      slug "echo"
      data("params") { |request| request.params }
    end
    Robin::Web.register(page)
    get "/robin/api/extensions/echo/data/params", {"x" => "1"}

    assert_json_response 200, {"x" => "1"}
  end

  def test_page_messages_and_action_body
    with_files(FILES) do |dir|
      Robin::Web.register(scripted_page(dir))
      get "/robin/api/extensions/reports", {"locale" => "de"}

      assert_equal({"Reports" => "Berichte", "Saved {name} in {place}" => "{name} in {place} gespeichert", "Done" => "Erledigt"}, json["messages"])
      assert_equal "extensions/reports/app.js", json["script"]
      assert_equal [{"type" => "heading", "text" => "Berichte"}], json["blocks"]
      post_json "/robin/api/extensions/reports/actions/quiet?locale=de"

      assert_json_response 200, {"message" => "Erledigt"}
      post_json "/robin/api/extensions/reports/actions/save?locale=de", {"name" => "Q3"}

      assert_json_response 200, {"message" => "Q3 in de gespeichert"}
      post_json "/robin/api/extensions/reports/actions/save"

      assert_json_response 200, {"message" => "Saved  in en"}
      get "/robin/api/session"

      assert_equal({"de" => "Berichte", "pt" => "Relatórios", "zh-TW" => "報告"}, json["extensions"].first["titles"])
    end
  end
end
