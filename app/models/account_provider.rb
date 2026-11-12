class AccountProvider < ApplicationRecord
  belongs_to :account
  belongs_to :provider, polymorphic: true

  has_many :holdings, dependent: :nullify

  validates :account_id, uniqueness: { scope: :provider_type }
  validates :provider_id, uniqueness: { scope: :provider_type }

  validate :financekit_has_exclusive_writer, if: -> { new_record? || will_save_change_to_account_id? || will_save_change_to_provider_id? || will_save_change_to_provider_type? }

  # Returns the provider adapter for this connection
  def adapter
    Provider::Factory.create_adapter(provider, account: account)
  end

  # Convenience method to get provider name
  # Delegates to the adapter for consistency, falls back to underscored provider_type
  def provider_name
    adapter&.provider_name || provider_type.underscore
  end

  private

    def financekit_has_exclusive_writer
      # belongs_to :account already reports a missing account; bail out rather
      # than dereference it below.
      return if account.nil?
      # Every provider link takes the same canonical-account lock. This closes
      # the race between FinanceKit mapping and another provider's setup flow.
      Account.where(id: account_id).lock.pick(:id)
      others = self.class.where(account_id: account_id).where.not(id: id)
      conflict = provider_type == "FinancekitAccountLineage" ? others.exists? : others.where(provider_type: "FinancekitAccountLineage").exists?
      errors.add(:account, "already has an exclusive FinanceKit publisher") if conflict
      if provider_type == "FinancekitAccountLineage" && provider&.family_id != account.family_id
        errors.add(:account, "must belong to the FinanceKit enrollment family")
      end
    end
end
