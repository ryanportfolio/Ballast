require "test_helper"

class BudgetRolloverLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @budget = budgets(:one)
    @category = @budget.family.categories.create!(name: "Synthetic rollover category", color: "#4da568")
    @budget_category = @budget.budget_categories.create!(
      category: @category, budgeted_spending: 100, currency: "USD", rollover_enabled: true
    )
  end

  test "category detail renders the carried amount label" do
    previous = @budget.family.budgets.create!(
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: 1.month.ago.end_of_month.to_date,
      budgeted_spending: 25, expected_income: 100, currency: "USD"
    )
    previous.budget_categories.create!(
      category: @category, budgeted_spending: 25, currency: "USD", rollover_enabled: true
    )
    get budget_budget_category_path(@budget, @budget_category)

    assert_response :success
    assert_select "dt", text: "Rolled over"

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", budget_budget_category_path(@budget, @budget_category), text: /\+.*25.*rolled over/
  end

  test "category form renders rollover copy" do
    get budget_budget_categories_path(@budget)

    assert_response :success
    assert_select "label", text: "Rollover"
    assert_select "div[title=?]", "Keep this category's unspent money from one month to the next"
  end
end
