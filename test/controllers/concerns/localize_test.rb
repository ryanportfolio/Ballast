require "test_helper"

class LocalizeTest < ActionDispatch::IntegrationTest
  test "renders English when the locale param asks for another language" do
    sign_in users(:family_admin)

    get preferences_onboarding_url(locale: "de")
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "renders English when Accept-Language asks for another language" do
    sign_in users(:family_admin)

    get preferences_onboarding_url, headers: { "Accept-Language" => "de-DE,de;q=0.9" }
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "renders English when the stored user and family locale is de" do
    user = users(:family_admin)
    # Raw SQL: update_column would run the locale normalizer and store nil/"en".
    User.connection.exec_update("UPDATE users SET locale = 'de' WHERE id = #{User.connection.quote(user.id)}")
    Family.connection.exec_update("UPDATE families SET locale = 'de' WHERE id = #{Family.connection.quote(user.family_id)}")
    assert_equal "de", user.reload.read_attribute(:locale)
    assert_equal "de", user.family.reload.read_attribute(:locale)
    sign_in user

    get preferences_onboarding_url
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "falls back to default timezone and logs a warning when family timezone is unrecognized" do
    user = users(:family_admin)
    # A deliberately nonexistent zone name, standing in for a stale/renamed IANA
    # value slipping past validation (e.g. the historical "Europe/Kiev" ->
    # "Europe/Kyiv" rename, or a migration that never ran). We can't use a real
    # legacy alias like "Europe/Kiev" here: whether tzinfo still recognizes it
    # depends on the host's installed tzdata version, which would make this
    # test non-deterministic across machines/CI.
    user.family.update_column(:timezone, "Invalid/Timezone")
    sign_in user

    assert_difference "DebugLogEntry.count", 1 do
      get root_url
    end

    assert_response :success

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "warn", entry.level
    assert_includes entry.message, "Invalid/Timezone"
    assert_equal user.family, entry.family
  end

  test "does not log when family timezone is valid" do
    user = users(:family_admin)
    user.family.update_column(:timezone, "America/New_York")
    sign_in user

    assert_no_difference "DebugLogEntry.count" do
      get root_url
    end

    assert_response :success
  end

  test "does not log again on a second request within the debounce window" do
    user = users(:family_admin)
    user.family.update_column(:timezone, "Invalid/Timezone")
    sign_in user

    # The test environment's cache store is :null_store (config/environments/test.rb),
    # which never actually caches anything -- every write is a no-op and every
    # key looks nonexistent. Swap in a real store for this test so the
    # debounce lease (Rails.cache.write unless_exist:) is meaningfully
    # exercised instead of trivially passing.
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    assert_difference "DebugLogEntry.count", 1 do
      get root_url
      get root_url
      get root_url
    end

    assert_response :success
  ensure
    Rails.cache = original_cache
  end
end
