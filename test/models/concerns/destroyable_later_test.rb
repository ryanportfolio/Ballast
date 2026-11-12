require "test_helper"

class DestroyableLaterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @item = plaid_items(:one)
  end

  test "flags the item and enqueues its destruction" do
    assert_enqueued_with(job: DestroyJob, args: [ @item ]) do
      assert @item.destroy_later
    end

    assert @item.reload.scheduled_for_deletion?
    assert_not_includes PlaidItem.syncable, @item
  end

  # The adapter is stubbed rather than perform_later, so ActiveJob's own
  # enqueue path decides what destroy_later sees. This is what an unreachable
  # Redis looks like through the Sidekiq adapter: the push raises straight out.
  test "restores the flag and re-raises when the enqueue raises" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { @item.destroy_later }

    assert_not @item.reload.scheduled_for_deletion?
    assert_includes PlaidItem.syncable, @item
  end

  # An adapter raising ActiveJob::EnqueueError (or an enqueue callback aborting)
  # makes perform_later return false instead of raising.
  test "restores the flag when the enqueue is rejected" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "rejected")

    assert_equal false, @item.destroy_later

    assert_not @item.reload.scheduled_for_deletion?
  end

  # The Delete menu stays visible on a flagged item, so a second request is how
  # a connection stuck by an earlier lost enqueue gets deleted.
  test "re-enqueues destruction for an item that is already flagged" do
    @item.update_column(:scheduled_for_deletion, true)

    assert_enqueued_with(job: DestroyJob, args: [ @item ]) do
      assert @item.destroy_later
    end

    assert @item.reload.scheduled_for_deletion?
  end

  # A retry that fails must not clear the flag an earlier request set: that
  # request's DestroyJob is still queued, and clearing the flag would put the
  # item back into active/syncable until the job runs.
  test "a failed retry keeps the flag set by an earlier successful request" do
    @item.destroy_later
    assert_enqueued_jobs 1, only: DestroyJob

    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")
    assert_raises(RedisClient::CannotConnectError) { @item.destroy_later }

    assert @item.reload.scheduled_for_deletion?
  end

  test "a rejected retry keeps the flag set by an earlier successful request" do
    @item.destroy_later

    DestroyJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "rejected")
    assert_equal false, @item.destroy_later

    assert @item.reload.scheduled_for_deletion?
  end

  # A validation unrelated to deletion must not make a connection undeletable.
  # An item that checks a field against an allowlist on every save would fail
  # update! for a row written before the allowlist changed.
  test "flags an item that fails an unrelated validation" do
    @item.stubs(:valid?).returns(false)

    assert_enqueued_with(job: DestroyJob, args: [ @item ]) do
      assert @item.destroy_later
    end

    assert @item.reload.scheduled_for_deletion?
  end

  # A restore that re-ran validations would raise RecordInvalid here for an
  # item that no longer validates, masking the enqueue error and leaving the
  # flag set.
  test "restores the flag without re-running validations" do
    @item.stubs(:valid?).returns(false)
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { @item.destroy_later }

    assert_not @item.reload.scheduled_for_deletion?
  end

  # Every table with the flag gets its destroy_later from here, so a new provider
  # (or a local override) can't reintroduce the unguarded version.
  # Tables Ballast keeps after deleting the provider code that used them.
  REMOVED_PROVIDER_TABLES = %w[
    binance_items coinbase_items coinspot_items coinstats_items kraken_items onchain_wallet_items
    ibkr_items indexa_capital_items questrade_items snaptrade_items trade_republic_items trading212_items
    akahu_items fio_items lunchflow_items monobank_items redbark_items sophtron_items up_items
    brex_items enable_banking_items mercury_items wise_items
  ].freeze

  test "every model with a scheduled_for_deletion column uses the concern" do
    connection = ActiveRecord::Base.connection
    models = (connection.tables - REMOVED_PROVIDER_TABLES)
      .select { |table| connection.column_exists?(table, :scheduled_for_deletion) }
      .map { |table| table.classify.constantize }

    assert_operator models.size, :>=, 2

    models.each do |model|
      assert_equal DestroyableLater, model.instance_method(:destroy_later).owner,
        "#{model.name}#destroy_later must come from DestroyableLater"
    end
  end
end
