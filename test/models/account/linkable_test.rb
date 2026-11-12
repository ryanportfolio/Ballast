require "test_helper"

class Account::LinkableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "linked? returns true when account has providers" do
    link_account_to_simplefin!(@account)

    assert @account.linked?
  end

  test "linked? returns false when account has no providers" do
    assert @account.unlinked?
  end

  test "providers returns all provider adapters" do
    link_account_to_simplefin!(@account)

    providers = @account.providers
    assert_equal 1, providers.count
    assert_kind_of Provider::SimplefinAdapter, providers.first
  end

  test "provider_for returns specific provider adapter" do
    link_account_to_simplefin!(@account)

    adapter = @account.provider_for("SimplefinAccount")
    assert_kind_of Provider::SimplefinAdapter, adapter
  end

  test "linked_to? checks if account is linked to specific provider type" do
    link_account_to_simplefin!(@account)

    assert @account.linked_to?("SimplefinAccount")
    refute @account.linked_to?("OtherProviderAccount")
  end

  test "supports_category_matcher? returns false for unlinked accounts and providers without a matcher" do
    refute @account.supports_category_matcher?

    simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/access_token"
    )
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: simplefin_item,
      name: "Test Account",
      account_id: "test-acct",
      currency: "USD",
      account_type: "checking",
      current_balance: 0
    )
    @account.update!(simplefin_account: simplefin_account)

    refute @account.supports_category_matcher?
  end

  test "can_delete_holdings? returns true for unlinked accounts" do
    assert @account.unlinked?
    assert @account.can_delete_holdings?
  end

  test "can_delete_holdings? returns false when any provider disallows deletion" do
    link_account_to_simplefin!(@account)

    # SimplefinAdapter.can_delete_holdings? returns false
    refute @account.can_delete_holdings?
  end

  test "can_delete_holdings? returns true only when all providers allow deletion" do
    link_account_to_simplefin!(@account)

    # Stub all providers to return true
    @account.providers.each do |provider|
      provider.stubs(:can_delete_holdings?).returns(true)
    end

    assert @account.can_delete_holdings?
  end

  # The `linked` scope mirrors `linked?` at the SQL level. These tests pin
  # both link types so a future schema or `linked?` change breaks the
  # test instead of silently diverging (e.g. wrong sparkline aggregation).
  test "linked scope matches accounts linked via account_providers" do
    link_account_to_simplefin!(@account)

    assert_includes Account.linked, @account
  end

  test "linked scope matches accounts with legacy simplefin_account_id" do
    simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/access_token"
    )
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: simplefin_item,
      name: "Test Account",
      account_id: "test-acct",
      currency: "USD",
      account_type: "checking",
      current_balance: 0
    )
    @account.update!(simplefin_account: simplefin_account)

    assert_includes Account.linked, @account
  end

  test "linked scope excludes manual accounts" do
    assert @account.unlinked?
    refute_includes Account.linked, @account
  end
end
