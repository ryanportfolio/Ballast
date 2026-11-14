require "test_helper"

class ConfigurationHealth::OptionalServicesTest < ActiveSupport::TestCase
  ENVIRONMENT = %w[
    SENTRY_DSN
    SKYLIGHT_AUTHENTICATION SKYLIGHT_ENABLED POSTHOG_KEY POSTHOG_HOST
    POSTHOG_FEEDBACK_ENABLED POSTHOG_DEVELOPMENT_ENABLED LOGTAIL_API_KEY LOGTAIL_INGESTING_HOST
  ].index_with(nil).freeze

  setup do
    @health = ConfigurationHealth::OptionalServices.new
    @posthog = Rails.configuration.x.posthog.clone
    @posthog.api_key = nil
    @posthog.host = "https://us.i.posthog.com"
    @posthog.development_enabled = false
    @posthog.feedback_enabled = true
    Sentry.stubs(:configuration).returns(nil)
    Rails.configuration.x.stubs(:posthog).returns(@posthog)
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Rails.stubs(:env).returns("test".inquiry)
  end

  test "absent optional services are informational and initialize no clients" do
    Sentry.expects(:init).never
    Sentry.expects(:capture_exception).never
    Sentry.expects(:capture_message).never
    PostHog::Client.expects(:new).never
    Logtail::Logger.expects(:create_default_logger).never

    with_environment do
      checks = @health.checks
      assert_equal %i[sentry skylight posthog logtail], checks.map(&:key)
      assert checks.all? { |check| check.status == :not_configured }
      assert checks.all? { |check| check.tone == :neutral }
      assert checks.all? { |check| check.settings.empty? }
    end
  end

  test "Sentry reports its actual loaded configuration and enabled environment" do
    config = Sentry::Configuration.new
    config.dsn = "https://private-key@sentry.example.test/123"
    config.enabled_environments = [ "production" ]
    Sentry.stubs(:configuration).returns(config)

    with_environment do
      config.environment = "development"
      assert_equal :disabled, @health.sentry.status
      config.environment = "production"
      assert_equal :configured, @health.sentry.status
      assert_no_match(/private-key/, @health.sentry.inspect)
    end
  end

  test "explicit Skylight false disables it even if authentication exists" do
    with_environment("SKYLIGHT_AUTHENTICATION" => "private-token", "SKYLIGHT_ENABLED" => "FaLsE") do
      assert_equal :disabled, @health.skylight.status
      assert_equal [ :explicitly_disabled ], @health.skylight.notes
    end
  end

  test "explicit Skylight opt in without authentication is incomplete" do
    with_environment("SKYLIGHT_ENABLED" => "true") do
      assert_equal :incomplete, @health.skylight.status
      assert_equal [ "SKYLIGHT_AUTHENTICATION" ], @health.skylight.settings
    end
  end

  test "Skylight reports configuration presence without reproducing SDK activation" do
    with_environment("SKYLIGHT_AUTHENTICATION" => "private-token") do
      assert_equal :configured, @health.skylight.status
      assert_no_match(/private-token/, @health.skylight.inspect)
    end
  end

  test "PostHog reads boot loaded settings rather than later environment changes" do
    with_environment("POSTHOG_KEY" => "later-key", "POSTHOG_HOST" => "https://later-host.test") do
      assert_equal :not_configured, @health.posthog.status
    end
    @posthog.api_key = "private-key"
    with_environment do
      assert_equal :configured, @health.posthog.status
      assert_no_match(/private-key/, @health.posthog.inspect)
      @posthog.host = ""
      assert_equal :incomplete, @health.posthog.status
      assert_equal [ "POSTHOG_HOST" ], @health.posthog.settings
    end
  end

  test "PostHog browser gating does not misreport the server client as disabled" do
    @posthog.api_key = "private-key"
    with_environment do
      assert_equal :configured, @health.posthog.status
      assert_includes @health.posthog.notes, :browser_analytics_disabled
      Rails.stubs(:env).returns("production".inquiry)
      assert_not_includes @health.posthog.notes, :browser_analytics_disabled
      Rails.stubs(:env).returns("development".inquiry)
      assert_includes @health.posthog.notes, :browser_analytics_disabled
      @posthog.development_enabled = true
      assert_not_includes @health.posthog.notes, :browser_analytics_disabled
    end
  end

  test "shared PostHog feedback is separate from operator analytics and consent" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    Rails.stubs(:env).returns("production".inquiry)
    with_environment do
      assert_equal :not_configured, @health.posthog.status
      assert_includes @health.posthog.notes, :shared_feedback_configured
      @posthog.api_key = "private-key"
      @posthog.feedback_enabled = false
      assert_equal :configured, @health.posthog.status
      assert_includes @health.posthog.notes, :shared_feedback_disabled
    end
  end

  test "Logtail needs both fields and is used only in production" do
    with_environment("LOGTAIL_API_KEY" => "private-key") do
      assert_equal :incomplete, @health.logtail.status
      assert_equal [ "LOGTAIL_INGESTING_HOST" ], @health.logtail.settings
    end
    with_environment("LOGTAIL_API_KEY" => "private-key", "LOGTAIL_INGESTING_HOST" => "private-host") do
      assert_equal :disabled, @health.logtail.status
      Rails.stubs(:env).returns("production".inquiry)
      assert_equal :configured, @health.logtail.status
      assert_no_match(/private-/, @health.logtail.inspect)
    end
  end

  private
    def with_environment(overrides = {}, &block)
      ClimateControl.modify(ENVIRONMENT.merge(overrides), &block)
    end
end
