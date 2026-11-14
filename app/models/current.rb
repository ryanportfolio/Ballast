class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session
  attribute :latest_sync_by_syncable, :latest_completed_sync_by_syncable, :syncing_by_syncable

  delegate :family, to: :user, allow_nil: true

  resets { @accessible_accounts = @finance_accounts = nil }

  def user
    session&.user
  end

  def accessible_accounts
    @accessible_accounts ||= (user ? user.accessible_accounts : family&.accounts)&.load
  end

  def finance_accounts
    @finance_accounts ||= (user ? user.finance_accounts : family&.accounts)&.load
  end

  def accessible_entries
    return family&.entries unless user
    family.entries.joins(:account).merge(Account.accessible_by(user))
  end

  # Entries the user may annotate (notes, category, merchant, tags). Same as
  # accessible_entries: every family member has full access.
  def annotatable_entries
    return family&.entries unless user
    family.entries.joins(:account).merge(Account.annotatable_by(user))
  end
end
