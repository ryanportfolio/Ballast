require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "new" do
    get new_registration_url
    assert_response :success
  end

  test "create redirects to correct URL" do
    post registration_url, params: { user: {
      email: "john@example.com",
      password: "Password1!" } }

    assert_redirected_to root_url
  end

  test "create rolls back registration when session creation fails" do
    RegistrationsController.any_instance.stubs(:create_session_for).returns(false)

    assert_no_difference "User.count" do
      post registration_url, params: { user: {
        email: "session-failure@example.com",
        password: "Password1!" } }
    end

    assert_response :unprocessable_entity
    assert_nil User.find_by(email: "session-failure@example.com")
  end

  test "first user of instance becomes super_admin" do
    # Clear all users to simulate fresh instance
    User.connection.disable_referential_integrity { User.delete_all }

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "firstuser@example.com",
        password: "Password1!" } }
    end

    first_user = User.find_by(email: "firstuser@example.com")
    assert first_user.super_admin?, "First user should be super_admin"
  end

  test "subsequent users become admin not super_admin" do
    # Ensure users exist from fixtures
    assert User.exists?

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "seconduser@example.com",
        password: "Password1!" } }
    end

    new_user = User.find_by(email: "seconduser@example.com")
    assert new_user.admin?, "Subsequent user should be admin"
    assert_not new_user.super_admin?, "Subsequent user should not be super_admin"
  end

  test "closed sign-up refuses the registration page and a new account" do
    with_self_hosting do
      Setting.onboarding_state = "closed"

      get new_registration_url
      assert_redirected_to new_session_url
      assert_equal I18n.t("registrations.closed"), flash[:alert]

      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "closed-signup@example.com",
          password: "Password1!" } }
      end
      assert_redirected_to new_session_url
    end
  end

  # Invitations and invite codes are gone; an instance that was invite-only
  # must refuse sign-up exactly as a closed one does.
  test "a stored invite_only state refuses sign-up like closed" do
    with_self_hosting do
      Setting.raw_onboarding_state = "invite_only"

      get new_registration_url
      assert_redirected_to new_session_url

      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "legacy-invite-only@example.com",
          password: "Password1!" } }
      end
      assert_redirected_to new_session_url
    end
  end

  test "a blank state with the legacy invite flag refuses sign-up" do
    with_self_hosting do
      Setting.where(var: "onboarding_state").delete_all
      Setting.require_invite_for_signup = true
      Setting.clear_cache

      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "legacy-invite-flag@example.com",
          password: "Password1!" } }
      end
      assert_redirected_to new_session_url
    end
  end

  test "open sign-up accepts a new account when self hosted" do
    with_self_hosting do
      Setting.onboarding_state = "open"

      assert_difference "User.count", +1 do
        post registration_url, params: { user: {
          email: "open-signup@example.com",
          password: "Password1!" } }
      end
      assert_redirected_to root_url
    end
  end
end
