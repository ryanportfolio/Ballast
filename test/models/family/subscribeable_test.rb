require "test_helper"

class Family::SubscribeableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "inactive_trial_for_cleanup includes families with expired paused trials" do
    inactive = families(:inactive_trial)
    results = Family.inactive_trial_for_cleanup

    assert_includes results, inactive
  end

  test "inactive_trial_for_cleanup excludes families with active subscriptions" do
    results = Family.inactive_trial_for_cleanup

    assert_not_includes results, @family
  end

  test "inactive_trial_for_cleanup excludes families within grace period" do
    inactive = families(:inactive_trial)
    inactive.subscription.update!(trial_ends_at: 5.days.ago)

    results = Family.inactive_trial_for_cleanup

    assert_not_includes results, inactive
  end

  test "inactive_trial_for_cleanup includes families with no subscription created long ago" do
    old_family = Family.create!(name: "Abandoned", created_at: 90.days.ago)

    results = Family.inactive_trial_for_cleanup

    assert_includes results, old_family

    old_family.destroy
  end

  test "inactive_trial_for_cleanup excludes recently created families with no subscription" do
    recent_family = Family.create!(name: "New")

    results = Family.inactive_trial_for_cleanup

    assert_not_includes results, recent_family

    recent_family.destroy
  end

  test "destroying a family removes its subscription row" do
    family = Family.create!(name: "Subscribed Family")
    family.start_subscription!("sub_real_123")
    subscription = family.subscription

    family.destroy!

    assert family.destroyed?
    assert_not Subscription.exists?(subscription.id)
  end

  test "requires_data_archive? returns false with few transactions" do
    inactive = families(:inactive_trial)
    assert_not inactive.requires_data_archive?
  end

  test "requires_data_archive? returns true with 12+ recent transactions" do
    inactive = families(:inactive_trial)
    account = inactive.accounts.create!(
      name: "Test", currency: "USD", balance: 0, accountable: Depository.new, status: :active
    )

    trial_end = inactive.subscription.trial_ends_at
    15.times do |i|
      account.entries.create!(
        name: "Txn #{i}", date: trial_end - i.days, amount: 10, currency: "USD",
        entryable: Transaction.new
      )
    end

    assert inactive.requires_data_archive?
  end

  test "requires_data_archive? returns false with 12+ transactions but none recent" do
    inactive = families(:inactive_trial)
    account = inactive.accounts.create!(
      name: "Test", currency: "USD", balance: 0, accountable: Depository.new, status: :active
    )

    # All transactions from early in the trial (more than 14 days before trial end)
    trial_end = inactive.subscription.trial_ends_at
    15.times do |i|
      account.entries.create!(
        name: "Txn #{i}", date: trial_end - 30.days - i.days, amount: 10, currency: "USD",
        entryable: Transaction.new
      )
    end

    assert_not inactive.requires_data_archive?
  end
end
