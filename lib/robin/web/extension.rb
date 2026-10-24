# frozen_string_literal: true

require "yaml"

module Robin
  class Web
    # A page of your own in the dashboard. Describe it with a few kinds of
    # blocks (no frontend code), and attach actions to its buttons:
    #
    #   class BillingPage < Robin::Web::Extension
    #     slug "billing"   # in its URL: /ext/billing
    #     title "Billing"  # the tab
    #
    #     def blocks(request)
    #       queued = Robin::Queue.new("invoices", config: request.config).size
    #       [
    #         {type: "stats", items: [{label: request.t("Invoices waiting"), value: queued}]},
    #         {type: "table", columns: ["Customer", "Total"], rows: Invoice.pending.map { [_1.customer, _1.total] }},
    #         {type: "text", text: "Invoices go out at 6am."},
    #         {type: "actions", items: [{label: "Send now", action: "send", confirm: "Send every invoice?"}]}
    #       ]
    #     end
    #
    #     action "send" do |request|
    #       SendInvoices.perform_async
    #       "Sending invoices" # shown to the user
    #     end
    #   end
    #
    #   Robin::Web.register(BillingPage)
    #
    # For anything blocks can't show, a page can bring its own frontend
    # code: a JavaScript module (and stylesheet) from a directory of
    # assets, which the dashboard loads into the page, plus JSON data
    # endpoints for it to call:
    #
    #   class ReportsPage < Robin::Web::Extension
    #     slug "reports"
    #     assets File.expand_path("reports", __dir__)  # served at <mount>/extensions/reports/
    #     script "reports.js"
    #     stylesheet "reports.css"
    #
    #     data "summary" do |request|                  # GET api/extensions/reports/data/summary
    #       {"late" => Report.late.count, "since" => request.params["since"]}
    #     end
    #   end
    #
    # The module's default export is called with the element to render
    # into and a context object (see the README), and may return a
    # function to call when the page goes away.
    #
    # Translations: with `translations dir`, dir/<language>.yml files map
    # English text to that language (e.g. de.yml: {"Billing": "Abrechnung"}).
    # The title is translated in the navigation, request.t translates text
    # in blocks and actions, and scripts get the messages as context.t.
    #
    # Viewing the page, its assets and data needs the :read permission;
    # running an action needs :extensions (see Robin::Web.authorize; the
    # resource is "extension:<slug>/<action>"). Blocks are JSON: strings,
    # numbers and booleans render as text, never as HTML.
    class Extension
      SLUG = /\A[a-z0-9][a-z0-9_-]*\z/

      # What blocks, actions and data blocks get: the dashboard request.
      # +params+ are the query parameters, +body+ an action's JSON body
      # (a Hash), +locale+ the dashboard's language.
      Request = Struct.new(:config, :params, :env, :locale, :body, :extension)

      class Request
        # +text+ in the dashboard's language (when the extension has a
        # translation for it), with {name} placeholders filled from +values+.
        def t(text, **values)
          translated = extension&.messages(locale)&.fetch(text, nil) || text
          translated.gsub(/\{(\w+)\}/) do |placeholder|
            # (The pattern's group always matches.)
            name = Regexp.last_match(1) #: String
            values.fetch(name.to_sym) { placeholder }
          end
        end
      end

      class << self
        def slug(value = nil)
          return @slug || raise(ArgumentError, "#{self} needs a slug") if value.nil?

          value = value.to_s
          raise ArgumentError, "extension slugs are lowercase letters, digits, - and _: #{value.inspect}" unless SLUG.match?(value)

          @slug = value
        end

        def title(value = nil)
          return @title || slug.capitalize if value.nil?

          @title = value.to_s
        end

        def action(name, &block)
          actions[name.to_s] = block
        end

        def actions = (@actions ||= {})

        # A JSON endpoint for the page's script; the block's value is the
        # response.
        def data(name, &block)
          data_sources[name.to_s] = block
        end

        def data_sources = (@data_sources ||= {})

        # The directory the page's script, stylesheet and other files are
        # served from.
        def assets(dir = nil)
          return @assets if dir.nil?

          @assets = File.expand_path(dir)
        end

        # The page's JavaScript module and stylesheet, relative to +assets+.
        def script(path = nil) = asset_setting(:@script, path)

        def stylesheet(path = nil) = asset_setting(:@stylesheet, path)

        # The directory of <language>.yml translation files, read once here.
        def translations(dir = nil)
          return @translations if dir.nil?

          @translations = File.expand_path(dir)
          @messages = Dir.glob("*.yml", base: @translations).to_h do |file|
            [File.basename(file, ".yml"), load_messages(File.join(@translations, file))]
          end
        end

        # English text => translation for +locale+ ("pt-BR" falls back to
        # pt.yml), or nil without translations for it.
        def messages(locale)
          all = @messages or return
          all[locale] || all[locale.to_s.split("-").first]
        end

        # The full path of an asset, or nil when there's no such file
        # inside the assets directory.
        def asset_file(path)
          return unless @assets

          file = File.expand_path(path, @assets)
          file if file.start_with?("#{@assets}/") && File.file?(file)
        end

        def to_h
          {
            "slug" => slug, "title" => title, "titles" => (titles if @messages),
            "script" => @script && "extensions/#{slug}/#{@script}",
            "stylesheet" => @stylesheet && "extensions/#{slug}/#{@stylesheet}"
          }.compact
        end

        private

        def asset_setting(name, path)
          return instance_variable_get(name) if path.nil?
          raise ArgumentError, "#{self} needs `assets dir` before its script or stylesheet" unless @assets

          instance_variable_set(name, path.to_s.delete_prefix("/"))
        end

        # The title in every language it's translated to.
        def titles = @messages.transform_values { |messages| messages[title] }.compact

        def load_messages(file)
          messages = YAML.safe_load_file(file)
          raise ArgumentError, "#{file} must map English text to translations" unless messages.instance_of?(Hash)

          messages.to_h { |english, translated| [english.to_s, translated.to_s] }
        end
      end

      # The page's blocks; override this.
      def blocks(_request) = []

      # Runs an action; returns the message to show.
      def run(name, request)
        block = self.class.actions.fetch(name)
        result = instance_exec(request, &block)
        result.instance_of?(String) ? result : request.t("Done")
      end

      # Runs a data block; returns its value.
      def fetch(name, request) = instance_exec(request, &self.class.data_sources.fetch(name))
    end
  end
end
