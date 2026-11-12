# Sure's managed (hosted) mode used this job to archive and destroy families
# whose trial ended without a subscription. Ballast never creates
# subscriptions, so if the app ever ran without SELF_HOSTED=true it would
# destroy every household older than 59 days. Ballast does not schedule it
# (config/schedule.yml) and it does nothing; the class stays so a job already
# in the queue finishes instead of raising.
class InactiveFamilyCleanerJob < ApplicationJob
  queue_as :scheduled

  def perform(*, **)
    Rails.logger.info("InactiveFamilyCleanerJob: disabled in Ballast, no families touched")
  end
end
