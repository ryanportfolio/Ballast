require "test_helper"

class SyncCleanerJobTest < ActiveSupport::TestCase
  test "reaps records stuck by lost jobs and spares fresh ones" do
    stuck_import = imports(:transaction)
    stuck_import.update_columns(status: "importing", updated_at: 7.hours.ago)

    stuck_revert = imports(:trade)
    stuck_revert.update_columns(status: "reverting", updated_at: 7.hours.ago)

    stuck_export = FamilyExport.create!(family: families(:dylan_family))
    stuck_export.update_columns(status: "processing", updated_at: 3.hours.ago)

    fresh_import = imports(:account)
    fresh_import.update_columns(status: "importing", updated_at: 1.hour.ago)

    fresh_export = FamilyExport.create!(family: families(:dylan_family))
    fresh_export.update_columns(status: "processing", updated_at: 30.minutes.ago)

    SyncCleanerJob.perform_now

    assert_equal "failed", stuck_import.reload.status
    assert_equal Import.interrupted_error_message, stuck_import.error

    assert_equal "revert_failed", stuck_revert.reload.status

    assert_equal "failed", stuck_export.reload.status

    assert_equal "importing", fresh_import.reload.status
    assert_equal "processing", fresh_export.reload.status
  end

  test "a failing sweep does not block the others" do
    Sync.expects(:clean).raises(StandardError.new("boom"))

    stuck_export = FamilyExport.create!(family: families(:dylan_family))
    stuck_export.update_columns(status: "processing", updated_at: 3.hours.ago)

    assert_nothing_raised do
      SyncCleanerJob.perform_now
    end

    assert_equal "failed", stuck_export.reload.status
  end

  test "reaped records are captured as debug log entries" do
    stuck_import = imports(:transaction)
    stuck_import.update_columns(status: "importing", updated_at: 7.hours.ago)

    assert_difference "DebugLogEntry.count", 1 do
      SyncCleanerJob.perform_now
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "background_jobs", entry.category
    assert_equal stuck_import.family, entry.family
    assert_equal stuck_import.id, entry.metadata["record_id"]
  end
end
