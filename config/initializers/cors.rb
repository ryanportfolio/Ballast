# frozen_string_literal: true

# CORS configuration for API access from external apps.
#
# This enables Cross-Origin Resource Sharing for the /api endpoints, allowing
# authorized clients to communicate with the Rails backend.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Allow requests from any origin for API endpoints
    # External clients and development environments need flexible CORS
    origins "*"

    # API endpoints for third-party integrations
    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400
  end
end
