# frozen_string_literal: true

require "test_helper"

class Api::V1::ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @read_key = ApiKey.create!(
      user: @user,
      name: "Chats Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @write_key = ApiKey.create!(
      user: @user,
      name: "Chats Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    get "/api/v1/chats"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    get "/api/v1/chats", headers: api_headers(@read_key)
    assert_response :forbidden

    response_body = JSON.parse(response.body)
    assert_equal "feature_disabled", response_body["error"]
  end

  test "rejects chat creation for a consenting user when the assistant type is mcp_only" do
    api_key = ApiKey.create!(
      user: @user,
      name: "MCP Only Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    get "/api/v1/chats", headers: api_headers(api_key)
    assert_response :success

    @user.family.update!(assistant_type: "mcp_only")

    assert_no_difference "Chat.count" do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI" },
        headers: api_headers(api_key)
    end

    assert_response :forbidden
    assert_equal "feature_disabled", JSON.parse(response.body)["error"]
  end

  test "should list chats with read scope" do
    get "/api/v1/chats", headers: api_headers(@read_key)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert response_body["chats"].is_a?(Array)
    assert response_body["pagination"].present?
  end

  test "should show chat with messages" do
    get "/api/v1/chats/#{@chat.id}", headers: api_headers(@read_key)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal @chat.id, response_body["id"]
    assert response_body["messages"].is_a?(Array)
  end

  test "should create chat with write scope" do
    assert_difference "Chat.count" do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI" },
        headers: api_headers(@write_key)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "New chat", response_body["title"]
  end

  test "should not create chat with read scope" do
    post "/api/v1/chats",
      params: { title: "New chat" },
      headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "should update chat" do
    patch "/api/v1/chats/#{@chat.id}",
      params: { title: "Updated title" },
      headers: api_headers(@write_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Updated title", response_body["title"]
  end

  test "should delete chat" do
    assert_difference "Chat.count", -1 do
      delete "/api/v1/chats/#{@chat.id}", headers: api_headers(@write_key)
    end

    assert_response :no_content
  end

  test "should not access other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    get "/api/v1/chats/#{other_chat.id}", headers: api_headers(@read_key)
    assert_response :not_found
  end

  test "should support API key authentication" do
    # Remove any existing API keys for this user
    @user.api_keys.destroy_all

    plain_key = ApiKey.generate_secure_key
    api_key = @user.api_keys.build(
      name: "Test API Key",
      scopes: [ "read_write" ]
    )
    api_key.key = plain_key
    api_key.save!

    get "/api/v1/chats", headers: { "X-Api-Key" => plain_key }
    assert_response :success
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
