# frozen_string_literal: true

require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  test "provider_summary for enable_banking asks for re-consent when the bank rejected an unexpired session" do
    @enable_banking_items = [ EnableBankingItem.new(session_id: "session", session_expires_at: 30.days.from_now, status: :requires_update) ]

    summary = provider_summary("enable_banking")

    assert_equal :warn, summary[:status]
    assert_equal I18n.t("settings.providers.meta.reconsent_required"), summary[:meta]
  end

  # A key provider_summary doesn't handle falls through to { status: :off },
  # which lists a connected provider under Available. Wise
  # shipped that way. One key at a time, so a branch that reads another
  # provider's items fails too.
  test "provider_summary is not off for any connected family panel provider" do
    item = OpenStruct.new(oauth_configured?: true)

    off = Settings::ProvidersController::FAMILY_PANEL_KEYS.select do |key|
      instance_variable_set(:"@#{key}_items", [ item ])
      status = provider_summary(key)[:status]
      instance_variable_set(:"@#{key}_items", nil)
      status == :off
    end

    assert_empty off
  end
end
