require "test_helper"

class AccountsNewLocalizationRenderTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
  end

  test "account creation renders the keyboard controls" do
    get new_account_url

    assert_response :success
    assert_select "button[data-action='list-keyboard-navigation#focusPrevious']", text: "Previous", count: 1
    assert_select "button[data-action='list-keyboard-navigation#focusNext']", text: "Next", count: 1
  end
end
