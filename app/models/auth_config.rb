# frozen_string_literal: true

class AuthConfig
  class << self
    def local_login_enabled?
      # Default to true if not configured to preserve existing behavior.
      value = Rails.configuration.x.auth.local_login_enabled
      value.nil? ? true : !!value
    end

    def local_admin_override_enabled?
      !!Rails.configuration.x.auth.local_admin_override_enabled
    end

    # Whether a registered passkey may be used to sign in on its own, skipping
    # both the password and the TOTP step. Defaults to true when unconfigured.
    def passkey_login_enabled?
      value = Rails.configuration.x.auth.passkey_login_enabled
      value.nil? ? true : !!value
    end

    # When the local login form should be visible on the login page.
    # - true when local login is enabled for everyone
    # - true when admin override is enabled (super-admin only backend guard)
    # - false when both are disabled
    def local_login_form_visible?
      local_login_enabled? || local_admin_override_enabled?
    end

    # When password-related features (e.g., password reset link) should be
    # visible. These are disabled whenever local login is turned off, even if
    # an admin override is configured.
    def password_features_enabled?
      local_login_enabled?
    end

    # Backend check to determine if a given user is allowed to authenticate via
    # local email/password credentials.
    #
    # - If local login is enabled, all users may authenticate locally (even if
    #   the email does not map to a user, preserving existing error semantics).
    # - If local login is disabled but admin override is enabled, only
    #   super-admins may authenticate locally.
    # - If both are disabled, local login is blocked for everyone.
    def local_login_allowed_for?(user)
      # When local login is globally enabled, everyone can attempt to log in
      # and we fall back to invalid credentials for bad email/password combos.
      return true if local_login_enabled?

      # From here on, local login is disabled except for potential overrides.
      return false unless user

      return user.super_admin? if local_admin_override_enabled?

      false
    end
  end
end
