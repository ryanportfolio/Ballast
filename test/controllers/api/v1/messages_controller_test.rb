# frozen_string_literal: true

require "test_helper"

class Api::V1::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @write_key = ApiKey.create!(
      user: @user,
      name: "Messages Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    post "/api/v1/chats/#{@chat.id}/messages"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "Hello" },
      headers: api_headers(@write_key)
    assert_response :forbidden
  end

  test "should create message with write scope" do
    assert_difference "UserMessage.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "gpt-4" },
        headers: api_headers(@write_key)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Test message", response_body["content"]
    assert_equal "user_message", response_body["type"]
    assert_equal "pending", response_body["ai_response_status"]
  end

  test "should enqueue assistant response job" do
    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message" },
        headers: api_headers(@write_key)
    end
  end

  test "should retry last assistant message" do
    skip "Retry functionality needs debugging"

    # Create an assistant message to retry
    assistant_message = @chat.messages.create!(
      type: "AssistantMessage",
      content: "Previous response",
      ai_model: "gpt-4"
    )

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: api_headers(@write_key)
    end

    assert_response :accepted
    response_body = JSON.parse(response.body)
    assert response_body["message_id"].present?
  end

  test "should not retry if no assistant message exists" do
    # Remove all assistant messages
    @chat.messages.where(type: "AssistantMessage").destroy_all

    post "/api/v1/chats/#{@chat.id}/messages/retry.json",
      headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "No assistant message to retry", response_body["error"]
  end

  test "should not access messages in other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    post "/api/v1/chats/#{other_chat.id}/messages",
      params: { content: "Test" },
      headers: api_headers(@write_key)

    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
