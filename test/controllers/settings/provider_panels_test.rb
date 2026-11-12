require "test_helper"

# The bank sync drawers share one layout: setup steps come from the shared
# setup_steps partial, messages are DS::Alerts and item actions are DS::Buttons.
class Settings::ProviderPanelsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "SimpleFIN lists its setup steps in the shared partial" do
    get connect_form_settings_providers_path(provider_key: "simplefin")

    assert_response :success
    assert_select "turbo-frame#simplefin-connect-form p", text: I18n.t("settings.providers.setup_steps.eyebrow")
  end

  test "SimpleFIN shows a rejected save in an error alert" do
    post simplefin_items_url, params: { source: "panel", simplefin_item: { setup_token: "" } }, as: :turbo_stream
    assert_error_alert "simplefin-providers-panel"
  end

  private
    # DS::Alert prefixes its text with the variant for screen readers ("Error: …").
    def assert_error_alert(target)
      assert_response :unprocessable_entity
      assert_select "turbo-stream[target=#{target}] template p", text: /\A\s*#{I18n.t("ds.alert.variants.error")}:\s+\S/
    end
end
