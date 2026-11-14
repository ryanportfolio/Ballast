require "test_helper"

class Assistant::Function::GetInsightsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetInsights.new(@user)
  end

  test "has correct name" do
    assert_equal "get_insights", @fn.name
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "returns visible insights with their metadata" do
    result = @fn.call

    assert result[:insights].any?

    anomaly = result[:insights].find { |i| i[:type] == "spending_anomaly" }

    assert_not_nil anomaly
    assert anomaly[:title].present?
    assert anomaly[:metadata].present?
  end

  test "excludes acknowledged insights by default and includes them on request" do
    acknowledged = @family.insights.first
    acknowledged.update!(status: "acknowledged")

    default_ids = @fn.call[:insights].map { |i| i[:id] }

    assert_not_includes default_ids, acknowledged.id

    included_ids = @fn.call("include_acknowledged" => true)[:insights].map { |i| i[:id] }

    assert_includes included_ids, acknowledged.id
  end

  test "filters by insight_type and clamps limit" do
    result = @fn.call("insight_type" => "cash_flow_warning", "limit" => 999)

    assert result[:insights].all? { |i| i[:type] == "cash_flow_warning" }
  end

  test "limit clamps to the maximum with more matching insights than the cap" do
    (Assistant::Function::GetInsights::MAX_LIMIT + 5).times do |i|
      @family.insights.create!(
        insight_type: "spending_anomaly",
        priority: "low",
        status: "active",
        title: "Clamp insight #{i}",
        body: "Body #{i}",
        currency: "USD",
        period_start: Date.current.beginning_of_month,
        period_end: Date.current.end_of_month,
        generated_at: Time.current,
        dedup_key: "clamp-test-#{i}"
      )
    end

    result = @fn.call("limit" => 999)

    assert_equal Assistant::Function::GetInsights::MAX_LIMIT, result[:insights].size
  end

  test "does not mutate insight status" do
    assert_no_changes -> { @family.insights.order(:id).pluck(:status) } do
      @fn.call
    end
  end

  test "does not return another family's insights" do
    result = Assistant::Function::GetInsights.new(users(:empty)).call

    assert_empty result[:insights]
  end

  test "include_acknowledged still hides insights about another family's account" do
    other_account = families(:empty).accounts.create!(name: "Other Family Account", accountable: Depository.new, currency: "USD", balance: 0)
    insight = @family.insights.create!(
      insight_type: "idle_cash", priority: "low", status: "dismissed", title: "Idle", body: "body",
      metadata: { "account_id" => other_account.id }, dedup_key: "idle_cash:other_family",
      generated_at: Time.current
    )

    ids = @fn.call("include_acknowledged" => true)[:insights].map { |i| i[:id] }

    assert_not_includes ids, insight.id
  end

  # Ballast removed the budget and goal insights; their rows stay in the table.
  test "include_acknowledged leaves out insights of a removed type" do
    insight = @family.insights.new(
      insight_type: "budget_at_risk", priority: "low", status: "dismissed", title: "Budget", body: "body",
      metadata: {}, dedup_key: "budget_at_risk:removed", generated_at: Time.current
    )
    insight.save!(validate: false)

    ids = @fn.call("include_acknowledged" => true)[:insights].map { |i| i[:id] }

    assert_not_includes ids, insight.id
  end
end
