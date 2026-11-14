require "test_helper"

class Settings::SystemHealthNavigationLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
  end

  test "super admins see system health links in both navigation layouts" do
    sign_in users(:sure_support_staff)
    get settings_preferences_url

    assert_response :success
    assert_select "nav a[href='#{admin_system_health_path}']", text: "System health", count: 2
  end

  test "system health navigation remains hidden from other roles" do
    %i[family_admin family_member].each do |fixture|
      sign_in users(fixture)
      get settings_preferences_url

      assert_response :success
      assert_select "nav a[href='#{admin_system_health_path}']", count: 0
    end
  end
end
