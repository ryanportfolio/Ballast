module Onboardable
  extend ActiveSupport::Concern

  included do
    before_action :require_onboarding_and_upgrade
  end

  private
    # Ballast never bills, so only onboarding is required. The name stays
    # because other controllers skip this callback by name.
    def require_onboarding_and_upgrade
      return unless Current.user
      return unless redirectable_path?(request.path)

      redirect_to onboarding_path if Current.user.needs_onboarding?
    end

    def redirectable_path?(path)
      return false if path.starts_with?("/settings")
      return false if path.starts_with?("/onboarding")
      return false if path.starts_with?("/users")
      return false if path.starts_with?("/api")  # Exclude API endpoints from onboarding redirects

      [
        new_registration_path,
        new_session_path,
        new_password_reset_path,
        new_email_confirmation_path
      ].exclude?(path)
    end
end
