require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  setup do
    @filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  # MFA codes and OAuth/bank authorization codes all arrive as a bare "code"
  # and are credentials until they are spent.
  test "filters one-time codes and other bearer values from logs" do
    filtered = @filter.filter(
      code: "123456",
      simplefin_item: { access_url: "https://user:secret@bridge.example/simplefin" }
    )

    assert_equal "[FILTERED]", filtered[:code]
    assert_equal "[FILTERED]", filtered.dig(:simplefin_item, :access_url)
  end

  test "filters WebAuthn credential payloads but keeps credential ids readable" do
    filtered = @filter.filter(
      credential: { id: "abc", response: { signature: "sig" } },
      credential_id: "abc"
    )

    assert_equal "[FILTERED]", filtered[:credential]
    assert_equal "abc", filtered[:credential_id]
  end

  test "keeps descriptive codes readable" do
    filtered = @filter.filter(currency_code: "EUR", country_code: "DE", postal_code: "10115")

    assert_equal "EUR", filtered[:currency_code]
    assert_equal "DE", filtered[:country_code]
    assert_equal "10115", filtered[:postal_code]
  end
end
