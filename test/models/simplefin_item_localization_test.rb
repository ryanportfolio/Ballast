require "test_helper"

class SimplefinItemLocalizationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @simplefin_item = create_simplefin_item
  end

  test "sync summaries use account-aware pluralization" do
    sync = create_sync(total: 0, linked: 0, unlinked: 0)

    assert_summary sync, "No accounts found"

    sync.update!(sync_stats: sync_stats(total: 1, linked: 1, unlinked: 0))
    assert_summary sync, "1 account synced"

    sync.update!(sync_stats: sync_stats(total: 2, linked: 2, unlinked: 0))
    assert_summary sync, "2 accounts synced"

    sync.update!(sync_stats: sync_stats(total: 2, linked: 1, unlinked: 1))
    assert_summary sync, "1 synced, 1 need setup"

    sync.update!(sync_stats: sync_stats(total: 3, linked: 1, unlinked: 2))
    assert_summary sync, "1 synced, 2 need setup"
  end

  test "sync summaries fall back to linked and unlinked account counts" do
    all_synced_item = create_simplefin_item
    Sync.create!(syncable: all_synced_item, status: "completed", completed_at: Time.current)
    all_synced_provider_account = create_simplefin_account(all_synced_item, account_id: "all-synced", org_data: {})
    create_linked_account(all_synced_provider_account, name: "All-synced account")

    assert_item_summary all_synced_item, "1 account synced"

    partial_item = create_simplefin_item
    Sync.create!(syncable: partial_item, status: "completed", completed_at: Time.current)
    linked_provider_account = create_simplefin_account(partial_item, account_id: "linked-fallback", org_data: {})
    create_linked_account(linked_provider_account, name: "Linked fallback account")
    create_simplefin_account(partial_item, account_id: "unlinked-fallback", org_data: {})

    assert_item_summary partial_item, "1 synced, 1 need setup"
  end

  test "institution summaries render fallbacks and preserve provider names" do
    assert_institution_summary @simplefin_item, "No institutions connected"

    named_item = create_simplefin_item
    create_simplefin_account(named_item, account_id: "named", org_data: { "name" => "Fjord Bank" })
    assert_institution_summary named_item, "Fjord Bank"

    unnamed_item = create_simplefin_item
    create_simplefin_account(unnamed_item, account_id: "unnamed", org_data: { "id" => "provider-1" })
    assert_institution_summary unnamed_item, "1 institution"

    multiple_item = create_simplefin_item
    create_simplefin_account(multiple_item, account_id: "first", org_data: { "name" => "Fjord Bank" })
    create_simplefin_account(multiple_item, account_id: "second", org_data: { "name" => "Harbor Credit" })
    assert_institution_summary multiple_item, "2 institutions"
  end

  test "daily refresh limit message does not change the provider error" do
    provider_error = "SimpleFin rate limit: data refreshes at most once every 24 hours."
    sync = Sync.create!(
      syncable: @simplefin_item,
      status: "failed",
      failed_at: Time.current,
      error: provider_error
    )

    assert_equal "You've hit SimpleFIN's daily refresh limit. Please try again after the bridge refreshes (up to 24 hours).",
                 @simplefin_item.rate_limited_message
    assert_equal provider_error, sync.reload.error
  end

  test "stale successful sync message" do
    travel_to Time.zone.local(2026, 9, 2, 12) do
      Sync.create!(
        syncable: @simplefin_item,
        status: "completed",
        completed_at: 5.days.ago
      )

      assert_equal "Last successful sync was 5 days ago. Your SimpleFIN connection may need attention.",
                   @simplefin_item.stale_sync_status[:message]
    end
  end

  test "stale transaction message" do
    travel_to Time.zone.local(2026, 9, 2, 12) do
      Sync.create!(
        syncable: @simplefin_item,
        status: "completed",
        completed_at: 1.day.ago
      )
      account = Account.create!(
        family: @family,
        name: "Everyday account",
        accountable: Depository.new(subtype: "checking"),
        balance: 100,
        currency: "USD"
      )
      simplefin_account = create_simplefin_account(@simplefin_item, account_id: "linked", org_data: { "name" => "Fjord Bank" })
      account.update!(simplefin_account: simplefin_account)
      create_transaction(account: account, name: "Invented purchase", date: 20.days.ago.to_date)

      assert_equal "No new transactions in 20 days. Check your SimpleFIN dashboard to ensure your bank connections are active.",
                   @simplefin_item.reload.stale_sync_status[:message]
    end
  end

  private
    def create_simplefin_item
      SimplefinItem.create!(
        family: @family,
        name: "Invented SimpleFIN connection",
        access_url: "synthetic-simplefin-access"
      )
    end

    def create_simplefin_account(item, account_id:, org_data:)
      item.simplefin_accounts.create!(
        name: "Invented provider account",
        account_id: account_id,
        currency: "USD",
        account_type: "checking",
        current_balance: 100,
        org_data: org_data
      )
    end

    def create_sync(total:, linked:, unlinked:)
      Sync.create!(
        syncable: @simplefin_item,
        status: "completed",
        completed_at: Time.current,
        sync_stats: sync_stats(total: total, linked: linked, unlinked: unlinked)
      )
    end

    def create_linked_account(simplefin_account, name:)
      Account.create!(
        family: @family,
        name: name,
        accountable: Depository.new(subtype: "checking"),
        balance: 100,
        currency: "USD",
        simplefin_account: simplefin_account
      )
    end

    def sync_stats(total:, linked:, unlinked:)
      {
        "total_accounts" => total,
        "linked_accounts" => linked,
        "unlinked_accounts" => unlinked
      }
    end

    def assert_summary(sync, expected)
      sync.reload
      assert_equal expected, @simplefin_item.sync_status_summary
    end

    def assert_item_summary(item, expected)
      assert_equal expected, item.sync_status_summary
    end

    def assert_institution_summary(item, expected)
      assert_equal expected, item.institution_summary
    end
end
