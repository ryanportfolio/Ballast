# frozen_string_literal: true

require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  # A key provider_summary doesn't handle falls through to { status: :off },
  # which lists a connected provider under Available. A provider once
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
