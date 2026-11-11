module Family::Subscribeable
  extend ActiveSupport::Concern

  CLEANUP_GRACE_PERIOD = 14.days
  ARCHIVE_TRANSACTION_THRESHOLD = 12
  ARCHIVE_RECENT_ACTIVITY_WINDOW = 14.days

  included do
    has_one :subscription, dependent: :destroy

    scope :inactive_trial_for_cleanup, -> {
      cutoff_with_sub = CLEANUP_GRACE_PERIOD.ago
      cutoff_without_sub = (Subscription::TRIAL_DAYS.days + CLEANUP_GRACE_PERIOD).ago

      expired_trial = left_joins(:subscription)
        .where(subscriptions: { status: [ "paused", "trialing" ] })
        .where(subscriptions: { trial_ends_at: ...cutoff_with_sub })

      no_subscription = left_joins(:subscription)
        .where(subscriptions: { id: nil })
        .where(families: { created_at: ...cutoff_without_sub })

      where(id: expired_trial).or(where(id: no_subscription))
    }
  end

  def start_subscription!(stripe_subscription_id)
    if subscription.present?
      subscription.update!(status: "active", stripe_id: stripe_subscription_id)
    else
      create_subscription!(status: "active", stripe_id: stripe_subscription_id)
    end
  end

  def days_left_in_trial
    return -1 unless subscription.present?
    ((subscription.trial_ends_at - Time.current).to_i / 86400) + 1
  end

  def sync_trial_status!
    if subscription&.status == "trialing" && days_left_in_trial < 0
      subscription.update!(status: "paused")
    end
  end

  def requires_data_archive?
    return false unless transactions.count > ARCHIVE_TRANSACTION_THRESHOLD

    trial_end = subscription&.trial_ends_at || (created_at + Subscription::TRIAL_DAYS.days)
    recent_window_start = trial_end - ARCHIVE_RECENT_ACTIVITY_WINDOW

    entries.where(date: recent_window_start..trial_end).exists?
  end
end
