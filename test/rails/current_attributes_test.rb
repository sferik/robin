# frozen_string_literal: true

require_relative "helper"
require "rails"
require "active_job/railtie"
require "global_id"

module CurrentAttributesTest
  class Current < ActiveSupport::CurrentAttributes
    attribute :user, :tenant
  end

  class Request < ActiveSupport::CurrentAttributes
    attribute :id
  end

  # A record GlobalID can find again.
  class Person
    include GlobalID::Identification

    attr_reader :id

    def initialize(id) = @id = id

    def self.find(id) = new(Integer(id))

    def ==(other) = other.instance_of?(Person) && other.id == id
  end
end

class CurrentAttributesTests < Minitest::Test
  cover "Robin::Rails::CurrentAttributes*"

  Current = CurrentAttributesTest::Current
  Request = CurrentAttributesTest::Request
  Person = CurrentAttributesTest::Person
  NAMES = %w[CurrentAttributesTest::Current CurrentAttributesTest::Request].freeze

  def setup
    GlobalID.app = "robin-test"
    [Current, Request].each(&:reset)
    @config = Robin::Config.new
  end

  def teardown = [Current, Request].each(&:reset)

  def save(payload = {"class" => "T", "args" => []}, names: NAMES)
    result = Robin::Rails::CurrentAttributes::Save.new(names).call(nil, payload, "default", nil) { :pushed }
    [payload, result]
  end

  def load(payload, names: NAMES, &) = Robin::Rails::CurrentAttributes::Load.new(names).call(nil, payload, "default", &)

  def serialize(attributes) = ActiveJob::Arguments.serialize(attributes)

  def test_saves_set_attributes_and_round_trips_them
    Current.user = Person.new(7)
    Current.tenant = :acme
    Request.id = "r1"
    payload, result = save

    assert_equal :pushed, result
    assert_equal %w[class args cattr cattr_1], payload.keys
    assert_equal serialize({user: Person.new(7), tenant: :acme}), payload["cattr"]
    assert_equal "gid://robin-test/CurrentAttributesTest::Person/7", payload["cattr"].dig(0, 1, "_aj_globalid")
    assert_equal serialize({id: "r1"}), payload["cattr_1"]
    json = JSON.parse(JSON.generate(payload))
    [Current, Request].each(&:reset)

    seen = load(json) { [Current.user, Current.tenant, Request.id, :ran] }

    assert_equal [Person.new(7), :acme, "r1", :ran], seen
    assert_nil Current.user
    assert_nil Request.id
  end

  def test_nothing_is_saved_when_no_attribute_is_set
    Request.id = "r2"
    payload, = save(names: ["CurrentAttributesTest::Current"])

    assert_equal %w[class args], payload.keys
    payload, = save(names: NAMES)

    assert_equal %w[class args cattr_1], payload.keys
    assert_equal serialize({id: "r2"}), payload["cattr_1"]
  end

  def test_a_name_may_be_a_single_symbol
    Request.id = "r3"
    payload, = save(names: :"CurrentAttributesTest::Request")

    assert_equal serialize({id: "r3"}), payload["cattr"]
  end

  def test_save_keeps_attributes_already_in_the_job
    Current.tenant = :acme
    Request.id = "r6"
    payload, = save({"cattr" => "kept"})

    assert_equal({"cattr" => "kept", "cattr_1" => serialize({id: "r6"})}, payload)
  end

  def test_jobs_without_saved_attributes_just_run
    assert_equal :ran, load({}) { :ran }
  end

  def test_attributes_load_by_position
    payload = JSON.parse(JSON.generate({"cattr" => serialize({id: "r7"}), "cattr_1" => serialize({tenant: :acme})}))

    assert_equal ["r7", :acme], load(payload, names: NAMES.reverse) { [Request.id, Current.tenant] }
  end

  def test_only_classes_saved_in_the_job_load
    Current.tenant = :before
    payload = JSON.parse(JSON.generate({"cattr_1" => serialize({id: "r8"})}))

    assert_equal [:before, "r8"], load(payload) { [Current.tenant, Request.id] }
  end

  def test_unknown_classes_are_skipped
    payload = {"cattr" => serialize({id: 1}), "cattr_1" => serialize({id: "r4"})}

    assert_equal "r4", load(payload, names: ["Gone::Current", "CurrentAttributesTest::Request"]) { Request.id }
    assert_equal :ran, load({"cattr" => []}, names: ["Gone::Current"]) { :ran }
  end

  def test_attributes_removed_since_the_push_are_left_out
    payload = JSON.parse(JSON.generate({"cattr" => serialize({tenant: :acme, retired: 1})}))

    assert_equal :acme, load(payload) { Current.tenant }
  end

  def test_install
    Robin::Rails::CurrentAttributes.install(@config, [])
    Robin::Rails::CurrentAttributes.install(@config, nil)

    refute @config.client_middleware.exists?(Robin::Rails::CurrentAttributes::Save)
    refute @config.server_middleware.exists?(Robin::Rails::CurrentAttributes::Load)
    Robin::Rails::CurrentAttributes.install(@config, Current)

    assert_equal Robin::Rails::CurrentAttributes::Save, @config.client_middleware.entries.last.klass
    assert_equal Robin::Rails::CurrentAttributes::Load, @config.server_middleware.entries.first.klass
  end

  def test_through_the_chains
    Robin::Rails::CurrentAttributes.install(@config, "CurrentAttributesTest::Request")
    Request.id = "r5"
    payload = {"class" => "T", "args" => []}
    @config.client_middleware.invoke("T", payload, "default", nil) { payload }
    Request.reset

    assert_equal "r5", @config.server_middleware.invoke(Object.new, payload, "default") { Request.id }
  end
end
