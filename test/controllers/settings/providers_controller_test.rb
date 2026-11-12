require "test_helper"

class Settings::ProvidersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    # Exercise controller jobs independently of the daily login sync.
    families(:dylan_family).update!(auto_sync_on_login: false)
    ensure_tailwind_build
    # Provider credentials are instance-wide, so saving them takes a super
    # admin. Promote the fixture admin rather than switching users so the
    # family-scoped assertions below keep using dylan_family.
    users(:family_admin).update!(role: :super_admin)
    sign_in users(:family_admin)

    # Ensure provider adapters are loaded for all tests
    Provider::Factory.ensure_adapters_loaded
    stub_instance_wide_providers
  end

  test "GET /settings/bank_sync redirects permanently to /settings/providers" do
    get "/settings/bank_sync"
    assert_redirected_to "/settings/providers"
    assert_equal 301, response.status
  end

  test "can access when self hosting is disabled (managed mode)" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get settings_providers_url
    assert_response :success

    patch settings_providers_url, params: { setting: { example_bank_client_id: "test123" } }
    assert_redirected_to settings_providers_url
  end

  test "a family admin cannot change instance-wide provider credentials in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    sign_in users(:empty)

    patch settings_providers_url, params: { setting: { example_bank_client_id: "attacker", example_bank_secret: "attacker-secret" } }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("settings.providers.not_authorized"), flash[:alert]
    assert_nil Setting["example_bank_client_id"]
    assert_nil Setting["example_bank_secret"]
  end

  test "a family admin cannot change provider credentials on a self-hosted instance with several families" do
    with_self_hosting do
      sign_in users(:empty)

      patch settings_providers_url, params: { setting: { example_bank_client_id: "attacker" } }

      assert_redirected_to settings_providers_url
      assert_nil Setting["example_bank_client_id"]
    end
  end

  test "the admin of the only family on a self-hosted instance can change provider credentials" do
    with_self_hosting do
      Family.stubs(:count).returns(1)
      sign_in users(:empty)

      patch settings_providers_url, params: { setting: { example_bank_client_id: "own-client-id" } }

      assert_redirected_to settings_providers_url
      assert_equal "own-client-id", Setting["example_bank_client_id"]
    end
  ensure
    Setting["example_bank_client_id"] = nil
  end

  test "instance-wide provider forms are only offered to those who may save them" do
    instance_wide_forms = Provider::ConfigurationRegistry.all.map do |config|
      connect_form_settings_providers_path(provider_key: config.provider_key)
    end

    get settings_providers_url
    assert instance_wide_forms.any? { |path| response.body.include?(path) }

    sign_in users(:empty)

    get settings_providers_url
    assert_response :success
    assert instance_wide_forms.none? { |path| response.body.include?(path) }

    get connect_form_settings_providers_path(provider_key: "example_bank")
    assert_redirected_to settings_providers_path
    assert_equal I18n.t("settings.providers.not_authorized"), flash[:alert]
  end

  test "should get show when self hosting is enabled" do
    with_self_hosting do
      get settings_providers_url
      assert_response :success
    end
  end

  # A panel missing from family_panel_items reports :ok forever, however badly its
  # connection is doing: compute_provider_sync_health skips any key whose items are
  # absent, so no error badge ever reaches the page.
  test "a failed SimpleFIN sync surfaces as an error on the providers page" do
    item = SimplefinItem.create!(family: families(:dylan_family), name: "Failing", access_url: "https://example.com/access")
    item.syncs.create!(status: :failed)

    get settings_providers_url
    assert_response :success

    health = @controller.view_assigns["provider_sync_health"]["simplefin"]
    assert health.present?, "simplefin is missing from the computed sync health"
    assert health[:error], "simplefin sync health should report an error"

    needs_attention = @controller.view_assigns["needs_attention"]
    assert_includes needs_attention.map { |entry| entry[:provider_key] }, "simplefin"
  end

  test "shows SimpleFIN as available when family has no SimpleFIN connections" do
    sign_in users(:empty)

    get settings_providers_url

    assert_response :success
    assert_includes response.body, "SimpleFIN"
    assert_includes response.body, I18n.t("settings.providers.taglines.simplefin")
    assert_select "details#simplefin-connection", count: 0
    assert_select "a[href=?]", connect_form_settings_providers_path(provider_key: "simplefin")
  end

  test "lists active SimpleFIN connections under your connections" do
    create_simplefin_connection

    get settings_providers_url

    assert_response :success
    assert_select "details#simplefin-connection"
    assert_select "a[href=?]", connect_form_settings_providers_path(provider_key: "simplefin"), count: 0
  end

  # Row panels used to sit in a frame of their own. A redirect to a page
  # without that frame showed "Content missing", and a stream to
  # "<key>-providers-panel" replaced the frame when the two shared that id.
  test "connection rows post from the page and leave panel ids unique" do
    create_simplefin_connection

    get settings_providers_url

    assert_response :success
    assert_operator css_select("details[id$='-connection']").size, :>=, 1
    assert_select "details[id$='-connection'] turbo-frame", count: 0

    panel_ids = css_select("[id$='-providers-panel']").map { |element| element["id"] }
    assert_equal panel_ids.uniq, panel_ids
  end

  # Saves and errors from a row or the drawer re-render the panel by replacing
  # "<turbo_id>-providers-panel".
  test "every streamed panel renders the root its streams replace" do
    Settings::ProvidersController::FAMILY_PANELS.each do |panel|
      get connect_form_settings_providers_url(provider_key: panel[:key])

      assert_response :success
      assert_select "##{panel[:turbo_id]}-providers-panel", 1, "#{panel[:key]} panel root"
    end
  end

  # The provider card reads its tagline with `default: nil`, so a missing key
  # renders a bare name rather than failing. Up shipped that way.
  test "every family panel provider has an English tagline" do
    missing = Settings::ProvidersController::FAMILY_PANEL_KEYS.reject do |key|
      I18n.exists?("settings.providers.taglines.#{key}", :en)
    end

    assert_empty missing
  end

  test "sync all control submits with POST" do
    SimplefinItem.create!(
      family: families(:dylan_family),
      name: "Test SimpleFIN Sync All Control",
      access_url: "https://bridge.simplefin.org/simplefin/access"
    )

    with_self_hosting do
      get settings_providers_url
      assert_response :success
      assert_select "form[action=?][method=?]", sync_all_settings_providers_path, "post"
    end
  end

  test "correctly identifies declared vs dynamic fields" do
    # All current provider fields are dynamic, but the logic should correctly
    # distinguish between declared and dynamic fields
    with_self_hosting do
      # example_bank_client_id is a dynamic field (not defined in Setting)
      refute Setting.singleton_class.method_defined?(:example_bank_client_id=),
        "example_bank_client_id= should NOT be defined on Setting's singleton class"

      # openai_model IS a declared field (defined in Setting)
      # but it's not a provider field, so it won't go through this controller
      assert Setting.singleton_class.method_defined?(:openai_model=),
        "openai_model= should be defined on Setting's singleton class"
    end
  end

  test "updates dynamic provider fields using batch update" do
    # example_bank_client_id is a dynamic field, stored as an individual entry
    with_self_hosting do
      # Clear any existing example_bank settings
      Setting["example_bank_client_id"] = nil

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "test_client_id" }
      }

      assert_redirected_to settings_providers_url
      assert_equal "test_client_id", Setting["example_bank_client_id"]
    end
  end

  test "batches multiple dynamic fields from same provider atomically" do
    # Test that multiple fields from one provider are updated as individual entries
    with_self_hosting do
      # Clear existing fields
      Setting["example_bank_client_id"] = nil
      Setting["example_bank_secret"] = nil
      Setting["example_bank_environment"] = nil

      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "new_client_id",
          example_bank_secret: "new_secret",
          example_bank_environment: "production"
        }
      }

      assert_redirected_to settings_providers_url

      # All three should be present as individual entries
      assert_equal "new_client_id", Setting["example_bank_client_id"]
      assert_equal "new_secret", Setting["example_bank_secret"]
      assert_equal "production", Setting["example_bank_environment"]
    end
  end

  test "batches dynamic fields from multiple providers atomically" do
    # Test that fields from different providers are stored as individual entries
    with_self_hosting do
      # Clear existing fields
      Setting["example_bank_client_id"] = nil
      Setting["example_bank_secret"] = nil
      Setting["example_bank_eu_client_id"] = nil
      Setting["example_bank_eu_secret"] = nil

      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "example_bank_client",
          example_bank_secret: "example_bank_secret",
          example_bank_eu_client_id: "example_bank_eu_client",
          example_bank_eu_secret: "example_bank_eu_secret"
        }
      }

      assert_redirected_to settings_providers_url

      # All fields should be present
      assert_equal "example_bank_client", Setting["example_bank_client_id"]
      assert_equal "example_bank_secret", Setting["example_bank_secret"]
      assert_equal "example_bank_eu_client", Setting["example_bank_eu_client_id"]
      assert_equal "example_bank_eu_secret", Setting["example_bank_eu_secret"]
    end
  end

  test "preserves existing dynamic fields when updating new ones" do
    # Test that updating some fields doesn't overwrite other existing fields
    with_self_hosting do
      # Set initial fields
      Setting["existing_field_1"] = "value1"
      Setting["example_bank_client_id"] = "old_client_id"

      # Update one field and add a new one
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "new_client_id",
          example_bank_secret: "new_secret"
        }
      }

      assert_redirected_to settings_providers_url

      # Existing unrelated field should still be there
      assert_equal "value1", Setting["existing_field_1"]

      # Updated field should have new value
      assert_equal "new_client_id", Setting["example_bank_client_id"]

      # New field should be added
      assert_equal "new_secret", Setting["example_bank_secret"]
    end
  end

  test "skips placeholder values for secret fields" do
    with_self_hosting do
      # Set an initial secret value
      Setting["example_bank_secret"] = "real_secret"

      # Try to update with placeholder
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "new_client_id",
          example_bank_secret: "********"  # Placeholder value
        }
      }

      assert_redirected_to settings_providers_url

      # Client ID should be updated
      assert_equal "new_client_id", Setting["example_bank_client_id"]

      # Secret should remain unchanged
      assert_equal "real_secret", Setting["example_bank_secret"]
    end
  end

  test "converts blank values to nil and removes from dynamic_fields" do
    with_self_hosting do
      # Set initial values
      Setting["example_bank_client_id"] = "old_value"
      assert_equal "old_value", Setting["example_bank_client_id"]
      assert Setting.key?("example_bank_client_id")

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "  " }  # Blank string with spaces
      }

      assert_redirected_to settings_providers_url
      assert_nil Setting["example_bank_client_id"]
      # Entry should be removed, not just set to nil
      refute Setting.key?("example_bank_client_id"),
        "nil values should delete the entry"
    end
  end

  test "handles sequential updates to different dynamic fields safely" do
    # This test simulates what would happen if two requests tried to update
    # different dynamic fields sequentially. With individual entries,
    # all changes should be preserved without conflicts.
    with_self_hosting do
      Setting["existing_field"] = "existing_value"

      # Simulate first request updating example_bank fields
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "client_id_1",
          example_bank_secret: "secret_1"
        }
      }

      # Existing field should still be there
      assert_equal "existing_value", Setting["existing_field"]

      # New fields should be added
      assert_equal "client_id_1", Setting["example_bank_client_id"]
      assert_equal "secret_1", Setting["example_bank_secret"]

      # Simulate second request updating different example_bank fields
      patch settings_providers_url, params: {
        setting: {
          example_bank_environment: "production"
        }
      }

      # All previously set fields should still be there
      assert_equal "existing_value", Setting["existing_field"]
      assert_equal "client_id_1", Setting["example_bank_client_id"]
      assert_equal "secret_1", Setting["example_bank_secret"]
      assert_equal "production", Setting["example_bank_environment"]
    end
  end

  test "only processes valid configuration fields" do
    with_self_hosting do
      # Try to update a field that doesn't exist in any provider configuration
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "valid_field",
          fake_field_that_does_not_exist: "should_be_ignored"
        }
      }

      assert_redirected_to settings_providers_url

      # Valid field should be updated
      assert_equal "valid_field", Setting["example_bank_client_id"]

      # Invalid field should not be stored
      assert_nil Setting["fake_field_that_does_not_exist"]
    end
  end

  test "calls reload_configuration on updated providers" do
    with_self_hosting do
      # Mock the adapter class to verify reload_configuration is called
      adapter = mock("example_bank_adapter")
      adapter.expects(:reload_configuration).once
      Provider::ConfigurationRegistry.stubs(:get_adapter_class).with("example_bank").returns(adapter)

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "new_client_id" }
      }

      assert_redirected_to settings_providers_url
    end
  end

  test "reloads configuration for multiple providers when updated" do
    with_self_hosting do
      # Both providers should have their configuration reloaded
      adapter = mock("example_bank_adapter")
      adapter.expects(:reload_configuration).once
      eu_adapter = mock("example_bank_eu_adapter")
      eu_adapter.expects(:reload_configuration).once
      Provider::ConfigurationRegistry.stubs(:get_adapter_class).with("example_bank").returns(adapter)
      Provider::ConfigurationRegistry.stubs(:get_adapter_class).with("example_bank_eu").returns(eu_adapter)

      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "example_bank_client",
          example_bank_eu_client_id: "example_bank_eu_client"
        }
      }

      assert_redirected_to settings_providers_url
    end
  end

  test "logs errors when update fails" do
    with_self_hosting do
      # Test that errors during update are properly logged and handled gracefully
      # We'll force an error by making the []= method raise
      Setting.expects(:[]=).with("example_bank_client_id", "test").raises(StandardError.new("Database error")).once

      # Mock logger to verify error is logged (pin both the exception class
      # name and the message so a regression that drops one still fails).
      Rails.logger.expects(:error).with(regexp_matches(/Failed to update provider settings: StandardError - Database error/)).once

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "test" }
      }

      # Controller should handle the error gracefully with generic message (no internal details)
      assert_response :unprocessable_entity
      assert_equal "Failed to update provider settings. Please try again.", flash[:alert]
    end
  end

  test "shows no changes message when no fields are updated" do
    with_self_hosting do
      # Only send a secret field with placeholder value (which gets skipped)
      Setting["example_bank_secret"] = "existing_secret"

      patch settings_providers_url, params: {
        setting: { example_bank_secret: "********" }
      }

      assert_redirected_to settings_providers_url
      assert_equal "No changes were made", flash[:notice]
    end
  end

  test "POST sync_all enqueues SyncAllProvidersJob" do
    SimplefinItem.create!(
      family: families(:dylan_family),
      name: "Test SimpleFIN Sync All",
      access_url: "https://bridge.simplefin.org/simplefin/access"
    )
    families(:dylan_family).update_column(:last_sync_all_attempted_at, nil)

    assert_enqueued_with(job: SyncAllProvidersJob) do
      post sync_all_settings_providers_path
    end

    assert_redirected_to settings_providers_path

    follow_redirect!
    assert_response :success
    assert_match(/Syncing all connected providers/i, response.body)
  end

  test "POST sync_all respects recent sync throttle" do
    families(:dylan_family).update_column(:last_sync_all_attempted_at, Time.current)

    assert_no_enqueued_jobs only: SyncAllProvidersJob do
      post sync_all_settings_providers_path
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("settings.providers.sync_all_recently"), flash[:notice]
  end

  test "POST sync for simplefin without an active Simplefin sync enqueues SyncJob" do
    item = SimplefinItem.create!(
      family: families(:dylan_family),
      name: "Test SimpleFIN Per Row Sync",
      access_url: "https://bridge.simplefin.org/simplefin/access"
    )
    Sync.where(syncable_type: "SimplefinItem", syncable_id: item.id).delete_all

    assert_enqueued_jobs 1, only: SyncJob do
      post sync_provider_settings_providers_path(provider_key: "simplefin")
    end

    assert_redirected_to settings_providers_path

    follow_redirect!
    assert_response :success
    assert_match(/Sync started/i, response.body)
  end

  test "GET connect_form warns on configured provider forms when self-hosted encryption keys are not explicitly configured" do
    Setting["example_bank_client_id"] = "test-client-id"
    Setting["example_bank_secret"] = "test-secret"
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    with_self_hosting do
      get connect_form_settings_providers_path(provider_key: "example_bank")

      assert_response :success
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    minimum: 1
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
    end
  ensure
    Setting["example_bank_client_id"] = nil
    Setting["example_bank_secret"] = nil
  end

  test "GET connect_form hides configured provider form encryption warning in managed mode" do
    Setting["example_bank_client_id"] = "test-client-id"
    Setting["example_bank_secret"] = "test-secret"
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    get connect_form_settings_providers_path(provider_key: "example_bank")

    assert_response :success
    assert_select "#config-connect-form input[name=?]", "setting[example_bank_client_id]"
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
    assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                  "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                  count: 0
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
    refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
  ensure
    Setting["example_bank_client_id"] = nil
    Setting["example_bank_secret"] = nil
  end

  test "GET connect_form warns when self-hosted encryption keys are not explicitly configured" do
    with_self_hosting do
      ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

      get connect_form_settings_providers_path(provider_key: "simplefin")

      assert_response :success
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    minimum: 1
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
      refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
    end
  end

  test "GET connect_form hides encryption warning when self-hosted encryption keys are configured" do
    with_self_hosting do
      ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

      get connect_form_settings_providers_path(provider_key: "simplefin")

      assert_response :success
      refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    count: 0
      refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
      refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
    end
  end

  test "GET connect_form hides encryption warning in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    get connect_form_settings_providers_path(provider_key: "simplefin")

    assert_response :success
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
    assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                  "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                  count: 0
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
    assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
    refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
  end

  test "GET connect_form uses shared encryption warning for provider panels" do
    with_self_hosting do
      ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

      get connect_form_settings_providers_path(provider_key: "simplefin")

      assert_response :success
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    minimum: 1
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
      refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
    end
  end

  test "non-admin users cannot update providers" do
    with_self_hosting do
      sign_in users(:family_member)

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "test" }
      }

      assert_redirected_to root_path
      assert_equal "Not authorized", flash[:alert]

      # Value should not have changed
      assert_nil Setting["example_bank_client_id"]
    end
  end

  test "uses singleton_class method_defined to detect declared fields" do
    with_self_hosting do
      # This test verifies the difference between respond_to? and singleton_class.method_defined?

      # openai_model is a declared field
      assert Setting.singleton_class.method_defined?(:openai_model=),
        "openai_model= should be defined on Setting's singleton class"
      assert Setting.respond_to?(:openai_model=),
        "respond_to? should return true for declared field"

      # example_bank_client_id is a dynamic field
      refute Setting.singleton_class.method_defined?(:example_bank_client_id=),
        "example_bank_client_id= should NOT be defined on Setting's singleton class"
      refute Setting.respond_to?(:example_bank_client_id=),
        "respond_to? should return false for dynamic field"

      # Both methods currently return the same result, but singleton_class.method_defined?
      # is more explicit and reliable for checking if a method is actually defined
    end
  end

  private
    # No adapter in this app declares instance-wide settings any more, so these
    # tests register two stand-in configurations the way a provider:global
    # adapter's `configure` block would.
    def stub_instance_wide_providers
      example_bank = Provider::Configurable::Configuration.new("example_bank")
      example_bank.field :client_id, label: "Client ID", required: true
      example_bank.field :secret, label: "Secret", required: true, secret: true
      example_bank.field :environment, label: "Environment", default: "sandbox"

      example_bank_eu = Provider::Configurable::Configuration.new("example_bank_eu")
      example_bank_eu.field :client_id, label: "Client ID", required: true
      example_bank_eu.field :secret, label: "Secret", required: true, secret: true

      Provider::ConfigurationRegistry.stubs(:all).returns([ example_bank, example_bank_eu ])
    end

    def create_simplefin_connection
      SimplefinItem.create!(
        family: families(:dylan_family),
        name: "Test SimpleFIN Connection",
        access_url: "https://bridge.simplefin.org/simplefin/access"
      )
    end
end
