require "test_helper"

class PasswordResetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "new" do
    get new_password_reset_path
    assert_response :ok
  end

  test "create" do
    assert_enqueued_emails 1 do
      post password_reset_path, params: { email: @user.email }
      assert_redirected_to new_password_reset_url(step: "pending")
    end
  end

  test "edit" do
    get edit_password_reset_path(token: @user.generate_token_for(:password_reset))
    assert_response :ok
  end

  test "update" do
    patch password_reset_path(token: @user.generate_token_for(:password_reset)),
      params: { user: { password: "password", password_confirmation: "password" } }
    assert_redirected_to new_session_url
  end

  test "all actions redirect when password features are disabled" do
    AuthConfig.stubs(:password_features_enabled?).returns(false)

    get new_password_reset_path
    assert_redirected_to new_session_path
    assert_equal "Password resets are disabled on this instance. Please contact your administrator.", flash[:alert]

    post password_reset_path, params: { email: @user.email }
    assert_redirected_to new_session_path
    assert_equal "Password resets are disabled on this instance. Please contact your administrator.", flash[:alert]

    get edit_password_reset_path(token: @user.generate_token_for(:password_reset))
    assert_redirected_to new_session_path
    assert_equal "Password resets are disabled on this instance. Please contact your administrator.", flash[:alert]

    patch password_reset_path(token: @user.generate_token_for(:password_reset)),
      params: { user: { password: "password", password_confirmation: "password" } }
    assert_redirected_to new_session_path
    assert_equal "Password resets are disabled on this instance. Please contact your administrator.", flash[:alert]
  end

  test "create sends email for user with local password" do
    assert @user.has_local_password?, "Test user should have local password"

    assert_enqueued_emails 1 do
      post password_reset_path, params: { email: @user.email }
    end

    assert_redirected_to new_password_reset_url(step: "pending")
  end
end
