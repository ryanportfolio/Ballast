require "test_helper"

class InactiveFamilyCleanerJobTest < ActiveJob::TestCase
  # Ballast never creates subscriptions, so the job must not destroy anything,
  # even in managed mode and for families the old cleanup would have removed.
  test "destroys and archives nothing, even in managed mode" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    inactive_family = families(:inactive_trial)
    old_family = Family.create!(name: "Abandoned", created_at: 90.days.ago)
    assert_nil old_family.subscription

    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(regexp_matches(/disabled in Ballast/)).twice

    assert_no_difference [ "Family.count", "ArchivedExport.count" ] do
      InactiveFamilyCleanerJob.perform_now
      InactiveFamilyCleanerJob.perform_now(dry_run: true)
    end

    assert Family.exists?(inactive_family.id)
    assert Family.exists?(old_family.id)
  end

  test "is not scheduled" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))

    assert_not schedule.values.any? { |entry| entry["class"] == "InactiveFamilyCleanerJob" }
  end
end
