require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  def with_origin_check
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  def with_codespaces_origin_check(&block)
    with_env_overrides(
      CODESPACES: "true",
      GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN: "app.github.dev",
      CODESPACE_NAME: "shiny-guide-6vj6x5qpjf5wpv",
      PORT: "3000"
    ) do
      Rails.env.stubs(:development?).returns(true)
      host! "shiny-guide-6vj6x5qpjf5wpv-3000.app.github.dev"
      https!
      with_origin_check(&block)
    end
  end

  test "codespaces accepts its localhost preview origin with a valid CSRF token" do
    with_codespaces_origin_check do
      get new_session_url
      token = css_select("input[name=authenticity_token]").first["value"]

      post sessions_url,
        params: { email: @user.email, password: user_password_test, authenticity_token: token },
        headers: { "Origin" => "https://localhost:3000" }

      assert_redirected_to root_url
      assert Session.exists?(user_id: @user.id)
    end
  end

  test "codespaces still requires a valid CSRF token" do
    with_codespaces_origin_check do
      post sessions_url,
        params: { email: @user.email, password: user_password_test },
        headers: { "Origin" => "https://localhost:3000" }

      assert_response :unprocessable_content
    end
  end

  test "codespaces still rejects unrelated origins" do
    with_codespaces_origin_check do
      get new_session_url
      token = css_select("input[name=authenticity_token]").first["value"]

      post sessions_url,
        params: { email: @user.email, password: user_password_test, authenticity_token: token },
        headers: { "Origin" => "https://attacker.example" }

      assert_response :unprocessable_content
    end
  end

  test "codespaces rejects a mismatched forwarded host with a valid CSRF token" do
    with_codespaces_origin_check do
      host! "other-codespace-3000.app.github.dev"
      get new_session_url
      token = css_select("input[name=authenticity_token]").first["value"]

      post sessions_url,
        params: { email: @user.email, password: user_password_test, authenticity_token: token },
        headers: { "Origin" => "https://localhost:3000" }

      assert_response :unprocessable_content
    end
  end

  test "codespaces rejects a mismatched localhost port with a valid CSRF token" do
    with_codespaces_origin_check do
      get new_session_url
      token = css_select("input[name=authenticity_token]").first["value"]

      post sessions_url,
        params: { email: @user.email, password: user_password_test, authenticity_token: token },
        headers: { "Origin" => "https://localhost:3001" }

      assert_response :unprocessable_content
    end
  end

  test "ordinary local development keeps standard same-origin validation" do
    Rails.env.stubs(:development?).returns(true)

    with_origin_check do
      host! "localhost:3000"
      get new_session_url
      token = css_select("input[name=authenticity_token]").first["value"]

      post sessions_url,
        params: { email: @user.email, password: user_password_test, authenticity_token: token },
        headers: { "Origin" => "http://localhost:3000" }

      assert_redirected_to root_url
    end
  end

  test "login page" do
    get new_session_url
    assert_response :success
  end

  test "login page offers passkey sign-in" do
    AuthConfig.stubs(:passkey_login_enabled?).returns(true)

    get new_session_url

    assert_response :success
    assert_select "button", text: I18n.t("sessions.new.passkey_button")
    assert_select "[data-webauthn-authentication-conditional-value='true']"
    assert_select "[data-webauthn-authentication-unsupported-message-value=?]", I18n.t("sessions.new.passkey_unsupported")
    assert_select "[data-webauthn-authentication-error-fallback-value=?]", I18n.t("passkey_sessions.invalid_credential")
    # Browsers only surface passkeys from autofill when the field carries the
    # "webauthn" token.
    assert_select "input[type=email][autocomplete='username webauthn']"
  end

  test "login page hides passkey sign-in when disabled" do
    AuthConfig.stubs(:passkey_login_enabled?).returns(false)

    get new_session_url

    assert_response :success
    assert_select "button", text: I18n.t("sessions.new.passkey_button"), count: 0
    assert_select "input[type=email][autocomplete='email']"
  end

  test "can sign in" do
    sign_in @user
    assert_redirected_to root_url
    assert Session.exists?(user_id: @user.id)

    get root_url
    assert_response :success
  end

  test "does not issue a session when user is deleted before row locking" do
    @user.stubs(:with_lock).raises(ActiveRecord::RecordNotFound)
    User.stubs(:authenticate_by).returns(@user)

    assert_no_difference("Session.count") do
      post sessions_url, params: { email: @user.email, password: user_password_test }
    end

    assert_redirected_to new_session_url
    assert cookies[:session_token].blank?
  end

  test "fails to sign in with bad password" do
    post sessions_url, params: { email: @user.email, password: "bad" }
    assert_response :unprocessable_entity
    assert_equal "Invalid email or password.", flash[:alert]
  end

  test "rejects fresh login for a deactivated user even with correct password" do
    # @user (family_admin) has a pre-existing fixture session (sessions.yml),
    # unrelated to this login attempt — clear it so the later assertion
    # actually proves no *new* session was created.
    @user.sessions.destroy_all

    # update_column bypasses the deactivation business rules (e.g. an admin
    # can't self-deactivate while other family members exist) since we're
    # testing the auth-layer guard, not User#deactivate itself.
    @user.update_column(:active, false)

    post sessions_url, params: { email: @user.email, password: user_password_test }

    assert_response :unprocessable_entity
    assert_equal "This account has been deactivated. Please contact an administrator.", flash[:alert]
    assert_not Session.exists?(user_id: @user.id)
  end

  test "an existing session stops working once the user is deactivated" do
    @user.sessions.destroy_all # Clean up the fixture session so the count below is exact
    sign_in @user
    assert Session.exists?(user_id: @user.id)

    @user.update_column(:active, false)

    get root_url
    assert_redirected_to new_session_path
    assert_not Session.exists?(user_id: @user.id), "stale session should be destroyed, not just skipped"
  end

  test "redirects when local login is disabled" do
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(false)

    post sessions_url, params: { email: @user.email, password: user_password_test }

    assert_redirected_to new_session_path
    assert_equal "Local password login is disabled.", flash[:alert]
  end

  test "allows super admin local login when override enabled" do
    super_admin = users(:sure_support_staff)

    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    post sessions_url, params: { email: super_admin.email, password: user_password_test }

    assert_redirected_to root_path
    assert Session.exists?(user_id: super_admin.id)
  end

  test "shows invalid credentials for super admin when override enabled but password is wrong" do
    super_admin = users(:sure_support_staff)

    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    post sessions_url, params: { email: super_admin.email, password: "bad" }

    assert_response :unprocessable_entity
    assert_equal "Invalid email or password.", flash[:alert]
  end

  test "blocks non-super-admin local login when override enabled" do
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    post sessions_url, params: { email: @user.email, password: user_password_test }

    assert_redirected_to new_session_path
    assert_equal "Local password login is disabled.", flash[:alert]
  end

  test "can sign out" do
    sign_in @user
    session_record = @user.sessions.last

    delete session_url(session_record)
    assert_redirected_to new_session_path
    assert_equal "You have signed out successfully.", flash[:notice]

    # Verify session is destroyed
    assert_nil Session.find_by(id: session_record.id)
  end

  test "rejects a deactivated MFA-enabled user before starting the MFA challenge" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.sessions.destroy_all
    @user.update_column(:active, false)

    post sessions_path, params: { email: @user.email, password: user_password_test }

    assert_response :unprocessable_entity
    assert_equal "This account has been deactivated. Please contact an administrator.", flash[:alert]
    assert_nil session[:mfa_user_id]
    assert_not Session.exists?(user_id: @user.id)
  end

  test "redirects to MFA verification when MFA enabled" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.sessions.destroy_all # Clean up any existing sessions

    post sessions_path, params: { email: @user.email, password: user_password_test }

    assert_redirected_to verify_mfa_path
    assert_equal @user.id, session[:mfa_user_id]
    assert_not Session.exists?(user_id: @user.id)
  end

  test "a session inactive past the timeout is rejected and destroyed" do
    sign_in @user
    session_record = Session.order(created_at: :desc).first
    session_record.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    get root_url
    assert_redirected_to new_session_url
    assert_not Session.exists?(session_record.id)
  end

  test "an active session is touched at most once per touch interval" do
    sign_in @user
    session_record = Session.order(created_at: :desc).first
    recent_activity = 5.minutes.ago
    session_record.update_column(:updated_at, recent_activity)

    get root_url
    assert_response :success
    session_record.reload
    assert_in_delta recent_activity, session_record.updated_at, 10.seconds
  end
end
