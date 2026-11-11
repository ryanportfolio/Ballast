# Ballast sends no telemetry. Sure's error, analytics, logging and tracing
# integrations stay in the code (they are called from dozens of files), but this
# initializer runs before theirs (initializers load in path order, so only
# 00_ssl.rb runs earlier) and removes the settings that would turn them on.
#
# Without this, Sure's PostHog setup sends daily usage events from every
# self-hosted production install to Sure's own PostHog project, using a key
# bundled in config/initializers/posthog.rb.
#
# Logtail: config/environments/production.rb always logs to STDOUT. Its keys are
# removed here too, so the system health page doesn't report Logtail as set up.
#
# SKYLIGHT_ENABLED is also read by Gemfile and config/application.rb before this
# runs; that only moves the gem between groups (require: false), it starts nothing.

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
  LOGTAIL_API_KEY
  LOGTAIL_INGESTING_HOST
].freeze

ignored = BALLAST_TELEMETRY_ENV.select { |key| ENV[key].present? }
ignored.each { |key| ENV.delete(key) }
ENV["POSTHOG_FEEDBACK_ENABLED"] = "false"

if ignored.any?
  Rails.logger.warn("Ballast ignores telemetry settings: #{ignored.join(', ')}")
end
