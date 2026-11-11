module Api
  module V1
    class AuthController < BaseController
      include Invitable

      skip_before_action :authenticate_request!
      skip_before_action :check_api_key_rate_limit
      skip_before_action :log_api_access
      before_action :authenticate_request!, only: :enable_ai
      before_action :ensure_write_scope, only: :enable_ai
      before_action :check_api_key_rate_limit, only: :enable_ai
      before_action :log_api_access, only: :enable_ai

      def signup
        # RegistrationsController refuses to register a user while the instance
        # is closed. That gate is declared `if: :self_hosted?`, but
        # onboarding_state only ever reaches "closed" on a self-hosted
        # instance, so checking the state alone matches its effect.
        if Setting.onboarding_state == "closed"
          render json: { error: "Registration is currently closed" }, status: :forbidden
          return
        end

        # Check if invite code is required
        if invite_code_required? && params[:invite_code].blank?
          render json: { error: "Invite code is required" }, status: :forbidden
          return
        end

        # Validate invite code if provided
        if params[:invite_code].present? && !InviteCode.exists?(token: params[:invite_code]&.downcase)
          render json: { error: "Invalid invite code" }, status: :forbidden
          return
        end

        # Validate password
        password_errors = validate_password(params[:user][:password])
        if password_errors.any?
          render json: { errors: password_errors }, status: :unprocessable_entity
          return
        end

        # Validate device info
        unless valid_device_info?
          render json: { error: "Device information is required" }, status: :bad_request
          return
        end

        user = User.new(user_signup_params)

        # Create family for new user
        # First user of an instance becomes super_admin
        family = Family.new
        user.family = family

        # Atomic: user creation, invite-code claim, and device/token issuance
        # either all commit or none do. Without this, a post-commit device
        # failure (e.g., racing uniqueness) would leave the user/invite/family
        # committed while the client got a 422 "Failed to register device".
        token_response = nil
        begin
          ActiveRecord::Base.transaction do
            User.lock_first_user_role!
            user.role = User.role_for_new_family_creator

            unless user.save
              render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
              raise ActiveRecord::Rollback
            end
            InviteCode.claim!(params[:invite_code]) if params[:invite_code].present?
            device = MobileDevice.upsert_device!(user, device_params)
            token_response = device.issue_token!
          end
        rescue ActiveRecord::RecordInvalid, User::InactiveError => e
          Rails.logger.error("[Auth] Device registration failed: #{e.class} - #{e.message}")
          render json: { error: "Failed to register device" }, status: :unprocessable_entity
          return
        end

        render json: token_response.merge(user: mobile_user_payload(user)), status: :created if token_response
      end

      def login
        user = User.find_by(email: params[:email])

        unless local_login_permitted_for?(user)
          render json: { error: "Local login is disabled." }, status: :forbidden
          return
        end

        if user&.authenticate(params[:password])
          unless user.active?
            render json: { error: "This account has been deactivated. Please contact an administrator." }, status: :unauthorized
            return
          end

          # Check MFA if enabled
          if user.otp_required?
            unless params[:otp_code].present? && user.verify_otp?(params[:otp_code])
              render json: {
                error: "Two-factor authentication required",
                mfa_required: true
              }, status: :unauthorized
              return
            end
          end

          # Validate device info
          unless valid_device_info?
            render json: { error: "Device information is required" }, status: :bad_request
            return
          end

          # Fast-path re-check to skip a pointless device upsert for a user
          # already known to be inactive — issue_token! re-checks active? under
          # lock immediately before minting (see its comment) and is the actual
          # authorization boundary, not this check. Treats a concurrently
          # purged user (reload raises RecordNotFound) the same as inactive.
          unless user_reloadable_and_active?(user)
            render json: { error: "This account has been deactivated. Please contact an administrator." }, status: :unauthorized
            return
          end

          begin
            device = MobileDevice.upsert_device!(user, device_params)
          rescue ActiveRecord::RecordInvalid => e
            Rails.logger.error("[Auth] Device registration failed: #{e.message}")
            render json: { error: "Failed to register device" }, status: :unprocessable_entity
            return
          end

          begin
            token_response = device.issue_token!
          rescue User::InactiveError
            render json: { error: "This account has been deactivated. Please contact an administrator." }, status: :unauthorized
            return
          end

          render json: token_response.merge(user: mobile_user_payload(user))
        else
          render json: { error: "Invalid email or password" }, status: :unauthorized
        end
      end

      def enable_ai
        user = current_resource_owner

        unless user.ai_available?
          render json: { error: "AI is not available for your account" }, status: :forbidden
          return
        end

        if user.update(ai_enabled: true)
          render json: { user: mobile_user_payload(user) }
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def refresh
        # Find the refresh token
        refresh_token = params[:refresh_token]

        unless refresh_token.present?
          render json: { error: "Refresh token is required" }, status: :bad_request
          return
        end

        # Find the access token associated with this refresh token
        access_token = Doorkeeper::AccessToken.by_refresh_token(refresh_token)

        if access_token.nil? || access_token.revoked?
          render json: { error: "Invalid refresh token" }, status: :unauthorized
          return
        end

        user = User.find_by(id: access_token.resource_owner_id)
        new_token = begin
          user&.with_active_lock! do
            access_token.with_lock do
              next false if access_token.revoked?

              token = Doorkeeper::AccessToken.create!( # pipelock:ignore Credential in URL
                application: access_token.application,
                resource_owner_id: access_token.resource_owner_id,
                mobile_device_id: access_token.mobile_device_id,
                expires_in: 30.days.to_i,
                scopes: access_token.scopes,
                use_refresh_token: true
              )

              access_token.revoke
              device = user.mobile_devices.find_by(device_id: params.dig(:device, :device_id))
              device&.update_last_seen!
              token
            end
          end
        rescue ActiveRecord::RecordNotFound, User::InactiveError
          false
        end

        unless new_token
          render json: { error: "Invalid refresh token" }, status: :unauthorized
          return
        end

        render json: {
          access_token: new_token.plaintext_token,
          refresh_token: new_token.plaintext_refresh_token,
          token_type: "Bearer",
          expires_in: new_token.expires_in,
          created_at: new_token.created_at.to_i
        }
      end

      private

        # Mirrors SessionsController#create: with local login disabled, the only
        # sign-in allowed is a super admin using the emergency override.
        def local_login_permitted_for?(user)
          return true if AuthConfig.local_login_enabled?

          AuthConfig.local_admin_override_enabled? && user&.super_admin?
        end

        def user_signup_params
          params.require(:user).permit(:email, :password, :first_name, :last_name)
        end

        def validate_password(password)
          errors = []

          if password.blank?
            errors << "Password can't be blank"
            return errors
          end

          errors << "Password must be at least 8 characters" if password.length < 8
          errors << "Password must include both uppercase and lowercase letters" unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)
          errors << "Password must include at least one number" unless password.match?(/\d/)
          errors << "Password must include at least one special character" unless password.match?(/[!@#$%^&*(),.?":{}|<>]/)

          errors
        end

        def valid_device_info?
          device = params[:device]
          return false if device.nil?

          required_fields = %w[device_id device_name device_type os_version app_version]
          return false unless required_fields.all? { |field| device[field].present? }

          # Run MobileDevice's attribute-level validations up front (e.g.,
          # device_type must be ios/android/web) so a misconfigured client
          # is rejected BEFORE signup commits user/family/invite. Skip
          # errors we can't evaluate without a user: the :user belongs_to
          # presence check, and device_id uniqueness scoped to user_id
          # (upsert_device! treats collisions as updates anyway).
          preview = MobileDevice.new(device_params)
          preview.valid?
          relevant_errors = preview.errors.errors.reject do |err|
            err.type == :taken || err.attribute == :user
          end
          relevant_errors.empty?
        end

        def device_params
          params.require(:device).permit(:device_id, :device_name, :device_type, :os_version, :app_version)
        end

        def mobile_user_payload(user)
          {
            id: user.id,
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            ui_layout: user.ui_layout,
            ai_enabled: user.ai_enabled?
          }
        end

        # A concurrent purge between the initial check and this fast-path
        # re-check raises RecordNotFound on reload; treat it the same as
        # inactive instead of letting it fall through to BaseController's
        # generic record_not_found handler.
        def user_reloadable_and_active?(user)
          user.reload.active?
        rescue ActiveRecord::RecordNotFound
          false
        end

        def ensure_write_scope
          authorize_scope!(:write)
        end
    end
  end
end
