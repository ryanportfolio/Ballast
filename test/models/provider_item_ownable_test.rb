require "test_helper"

class ProviderItemOwnableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin  = users(:family_admin)
    @member = users(:family_member)
    Current.reset
  end

  teardown { Current.reset }

  # No live provider item includes the concern today (SimpleFIN is tenant_wide
  # and admin-only), so anonymous models stand in for provider items. They sit
  # on the accounts table, which has the family_id and owner_id columns the
  # concern needs.
  def undeclared_item_class
    Class.new(ApplicationRecord) do
      self.table_name = "accounts"
      belongs_to :family
      include ProviderItemOwnable

      def self.name = "UndeclaredItem"
    end
  end

  # Stands in for a provider whose credential covers a single connection.
  def per_connection_item_class
    Class.new(ApplicationRecord) do
      self.table_name = "accounts"
      belongs_to :family
      include ProviderItemOwnable
      credential_scope :per_connection

      def self.name = "PerConnectionItem"
    end
  end

  def per_connection_item(owner:)
    per_connection_item_class.create!(family: @family, name: "Member Bank", owner: owner)
  end

  test "credential scope defaults to tenant_wide so an unclassified provider stays admin-only" do
    klass = undeclared_item_class

    assert_equal :tenant_wide, klass.declared_credential_scope
    assert_not klass.member_connectable?
  end

  test "credential scope rejects an unknown value" do
    error = assert_raises(ArgumentError) { undeclared_item_class.credential_scope(:sometimes) }
    assert_match(/unknown credential scope/, error.message)
  end

  test "owner defaults to the current user" do
    Current.session = @member.sessions.create!

    item = per_connection_item_class.create!(family: @family, name: "Member Bank")

    assert_equal @member, item.owner
  end

  test "owner falls back to a family admin when there is no current user" do
    item = per_connection_item_class.create!(family: @family, name: "Console Bank")

    assert_equal @admin, item.owner
  end

  test "owner must belong to the same family" do
    outsider = users(:empty)

    item = per_connection_item_class.new(family: @family, name: "Cross Family", owner: outsider)

    assert_not item.valid?
    assert_includes item.errors[:owner], "is invalid"
  end

  test "an admin may manage any connection in the family" do
    item = per_connection_item(owner: @member)

    assert item.manageable_by?(@admin)
  end

  test "a member may manage a per_connection item they own" do
    item = per_connection_item(owner: @member)

    assert item.manageable_by?(@member)
  end

  test "a member may not manage a connection owned by someone else" do
    item = per_connection_item(owner: @admin)

    assert_not item.manageable_by?(@member)
  end

  test "manageable_by? is false without a user" do
    assert_not per_connection_item(owner: @admin).manageable_by?(nil)
  end
end
