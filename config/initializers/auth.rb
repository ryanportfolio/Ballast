# frozen_string_literal: true

Rails.configuration.x.auth ||= ActiveSupport::OrderedOptions.new

begin
  raw_auth_config = Rails.application.config_for(:auth)
rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError => e
  Rails.logger.warn("Auth config not loaded: #{e.class} - #{e.message}")
  raw_auth_config = {}
end

auth_config = raw_auth_config.deep_symbolize_keys

Rails.configuration.x.auth.local_login_enabled = auth_config.dig(:local_login, :enabled)
Rails.configuration.x.auth.local_admin_override_enabled = auth_config.dig(:local_login, :admin_override_enabled)

Rails.configuration.x.auth.passkey_login_enabled = auth_config.dig(:passkey_login, :enabled)
