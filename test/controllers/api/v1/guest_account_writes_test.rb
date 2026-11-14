# frozen_string_literal: true

require "test_helper"

# Guests can read every account of their family but change none of them. The
# API finds records through the read scope, so each write action must check
# write access on the record's account itself.
class Api::V1::GuestAccountWritesTest < ActionDispatch::IntegrationTest
  setup do
    @guest = family_guest
    @member = users(:family_member)
    @transaction = transactions(:one)
    @entry = @transaction.entry
    @trade = trades(:one)
    @valuation_entry = entries(:valuation)
  end

  test "guest key can read a transaction" do
    get api_v1_transaction_url(@transaction), headers: headers_for(@guest)

    assert_response :success
  end

  test "guest key cannot update or delete a transaction" do
    patch api_v1_transaction_url(@transaction),
          params: { transaction: { name: "Guest rename" } },
          headers: headers_for(@guest)
    assert_forbidden

    assert_no_difference("Entry.count") do
      delete api_v1_transaction_url(@transaction), headers: headers_for(@guest)
    end
    assert_forbidden

    assert_equal "Starbucks", @entry.reload.name
  end

  test "guest key cannot create a transaction" do
    assert_no_difference("Entry.count") do
      post api_v1_transactions_url,
           params: { transaction: { account_id: @entry.account_id, name: "Guest", amount: 5, date: Date.current } },
           headers: headers_for(@guest)
    end
    assert_forbidden
  end

  test "guest key cannot create, update or delete a trade" do
    trade_entry = @trade.entry

    assert_no_difference("Entry.count") do
      post "/api/v1/trades",
           params: { trade: { account_id: trade_entry.account_id, type: "dividend", date: Date.current, amount: 5, ticker: "AAPL|XNAS" } },
           headers: headers_for(@guest)
      assert_forbidden

      patch "/api/v1/trades/#{@trade.id}", params: { trade: { name: "Guest rename" } }, headers: headers_for(@guest)
      assert_forbidden

      delete "/api/v1/trades/#{@trade.id}", headers: headers_for(@guest)
      assert_forbidden
    end

    assert_equal "Purchase 10 shares of AAPL", trade_entry.reload.name
  end

  test "guest key cannot create or update a valuation" do
    assert_no_difference("Entry.count") do
      post api_v1_valuations_url,
           params: { valuation: { account_id: @valuation_entry.account_id, amount: 1234, date: Date.current } },
           headers: headers_for(@guest)
    end
    assert_forbidden

    put api_v1_valuation_url(@valuation_entry), params: { valuation: { notes: "Guest note" } }, headers: headers_for(@guest)
    assert_forbidden
    assert_not_equal "Guest note", @valuation_entry.reload.notes
  end

  test "member key can still update a transaction, trade and valuation" do
    patch api_v1_transaction_url(@transaction),
          params: { transaction: { name: "Member rename" } },
          headers: headers_for(@member)
    assert_response :success
    assert_equal "Member rename", @entry.reload.name

    patch "/api/v1/trades/#{@trade.id}", params: { trade: { name: "Member trade" } }, headers: headers_for(@member)
    assert_response :success
    assert_equal "Member trade", @trade.entry.reload.name

    put api_v1_valuation_url(@valuation_entry), params: { valuation: { notes: "Member note" } }, headers: headers_for(@member)
    assert_response :success
    assert_equal "Member note", @valuation_entry.reload.notes
  end

  test "member key can still delete a transaction" do
    assert_difference("Entry.count", -1) do
      delete api_v1_transaction_url(@transaction), headers: headers_for(@member)
    end
    assert_response :success
  end

  private

    def assert_forbidden
      assert_response :forbidden
      assert_equal "forbidden", JSON.parse(response.body)["error"]
    end

    def headers_for(user)
      @keys ||= {}
      @keys[user.id] ||= begin
        user.api_keys.active.destroy_all
        ApiKey.create!(
          user: user,
          name: "Write Key #{SecureRandom.hex(4)}",
          key: ApiKey.generate_secure_key,
          scopes: %w[read_write],
          source: "web"
        )
      end
      { "X-Api-Key" => @keys[user.id].plain_key }
    end
end
