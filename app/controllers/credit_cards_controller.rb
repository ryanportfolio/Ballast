class CreditCardsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id,
    :available_credit,
    :minimum_payment,
    :apr,
    :annual_fee,
    :expiration_date,
    :statement_close_day,
    :due_day
  )

  def update
    super
    # Only apply provider settings once the account update succeeded (redirect);
    # a failed update renders :edit and must not persist the flag.
    if response.redirect?
      update_simplefin_settings
    end
  end

  private
    def update_simplefin_settings
      simplefin_params = params.permit(account: { simplefin: [ :balance_sign_override ] })
        .dig(:account, :simplefin)
      return if simplefin_params.blank?

      override = simplefin_params[:balance_sign_override]
      override = nil unless override.in?(%w[credit debt])

      update_provider_setting(
        provider_type: "SimplefinAccount",
        attribute: :balance_sign_override,
        value: override
      ) { |provider_account| provider_account.simplefin_item.sync_later }
    end

    def update_provider_setting(provider_type:, attribute:, value:)
      provider_account = @account.provider_account_for(provider_type)
      return unless provider_account.present?

      provider_account.update!(attribute => value)
      yield provider_account if provider_account.saved_change_to_attribute?(attribute)
    end
end
