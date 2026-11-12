require "test_helper"

class Settings::McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "shows MCP settings page" do
    get settings_mcp_path
    assert_response :success
  end

  test "non-admin member can view MCP settings" do
    sign_in users(:family_member)
    get settings_mcp_path
    assert_response :success
  end
end
