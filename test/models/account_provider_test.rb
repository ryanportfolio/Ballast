require "test_helper"

class AccountProviderTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @family = families(:dylan_family)

    # Create provider items
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Bank",
      access_url: "https://example.com/access"
    )

    # Create provider accounts
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "SimpleFin Checking",
      account_id: "sf_123",
      account_type: "checking",
      currency: "USD",
      current_balance: 2000
    )
  end

  test "prevents duplicate provider type for same account" do
    # Create first SimplefinAccount link
    AccountProvider.create!(
      account: @account,
      provider: @simplefin_account
    )

    # Create another SimplefinAccount
    another_simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "Another SimpleFin Account",
      account_id: "sf_456",
      account_type: "savings",
      currency: "USD",
      current_balance: 5000
    )

    # Should not be able to link another SimplefinAccount to same account
    duplicate_provider = AccountProvider.new(
      account: @account,
      provider: another_simplefin_account
    )

    assert_not duplicate_provider.valid?
    assert_includes duplicate_provider.errors[:account_id], "has already been taken"
  end

  test "prevents same provider account from linking to multiple accounts" do
    # Link provider to first account
    AccountProvider.create!(
      account: @account,
      provider: @simplefin_account
    )

    # Try to link same provider to another account
    another_account = accounts(:investment)

    duplicate_link = AccountProvider.new(
      account: another_account,
      provider: @simplefin_account
    )

    assert_not duplicate_link.valid?
    assert_includes duplicate_link.errors[:provider_id], "has already been taken"
  end

  test "adapter method returns correct adapter" do
    provider = AccountProvider.create!(
      account: @account,
      provider: @simplefin_account
    )

    adapter = provider.adapter

    assert_kind_of Provider::SimplefinAdapter, adapter
    assert_equal "simplefin", adapter.provider_name
    assert_equal @account, adapter.account
  end

  test "provider_name delegates to adapter" do
    simplefin_provider = AccountProvider.create!(
      account: accounts(:investment),
      provider: @simplefin_account
    )

    assert_equal "simplefin", simplefin_provider.provider_name
  end

  test "destroying account_provider keeps the provider account" do
    provider = AccountProvider.create!(
      account: @account,
      provider: @simplefin_account
    )

    simplefin_account_id = @simplefin_account.id

    assert SimplefinAccount.exists?(simplefin_account_id)

    provider.destroy!

    # Provider accounts remain (they can enter the "needs setup" state)
    assert SimplefinAccount.exists?(simplefin_account_id)
  end
end
