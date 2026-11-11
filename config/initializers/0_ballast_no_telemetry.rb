# Ballast sends no telemetry. Sure's error, analytics, logging and tracing
# integrations stay in the code (they are called from dozens of files), but this
# initializer runs before theirs (initializers load in path order) and removes
# the settings that would turn them on.
#
# Without this, Sure's PostHog setup sends daily usage events from every
# self-hosted production install to Sure's own PostHog project, using a key
# bundled in config/initializers/posthog.rb.
#
# Logtail is configured in config/environments/production.rb, which loads before
# initializers, so it is not covered here: never set LOGTAIL_API_KEY.

BALLAST_TELEMETRY_ENV = %w[
  SENTRY_DSN
  POSTHOG_KEY
  POSTHOG_HOST
  POSTHOG_SANKEY_SURVEY_ID
  POSTHOG_DEVELOPMENT_ENABLED
  LANGFUSE_PUBLIC_KEY
  LANGFUSE_SECRET_KEY
  LANGFUSE_HOST
  SKYLIGHT_AUTHENTICATION
  SKYLIGHT_ENABLED
].freeze

ignored = BALLAST_TELEMETRY_ENV.select { |key| ENV[key].present? }
ignored.each { |key| ENV.delete(key) }
ENV["POSTHOG_FEEDBACK_ENABLED"] = "false"

if ignored.any?
  Rails.logger.warn("Ballast ignores telemetry settings: #{ignored.join(', ')}")
end
