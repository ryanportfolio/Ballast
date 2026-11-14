require "test_helper"

class Family::AutoCategorizeTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    # Fresh family: fixture families carry categorized transactions.
    @family = Family.create!(name: "Auto-categorize Entry Family")
    @account = @family.accounts.create!(name: "Entry test", balance: 100, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
    @llm_provider = mock
  end

  test "the rule's auto-categorize runs the LLM" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
    txn = create_transaction(account: @account, name: "Starbucks Coffee").transaction

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: @groceries.name)
    ])).once

    assert_equal 1, @family.auto_categorize_transactions([ txn.id ])
    assert_equal @groceries, txn.reload.category
    assert_ai_categorization_log(transaction_ids: [ txn.id ])
  end

  test "without a provider the LLM raises" do
    txn = create_transaction(account: @account, name: "Something new").transaction

    error = assert_raises(Family::AutoCategorizer::Error) do
      @family.auto_categorize_transactions([ txn.id ])
    end
    assert_equal "No LLM provider for auto-categorization", error.message
  end

  private
    def assert_ai_categorization_log(transaction_ids:, categorized_transaction_ids: transaction_ids)
      log_entry = DebugLogEntry.order(:created_at).last

      assert_equal "auto_categorization", log_entry.category
      assert_equal "info", log_entry.level
      assert_equal "AI categorization completed", log_entry.message
      assert_equal "Family::AutoCategorizer", log_entry.source
      assert_equal @family, log_entry.family
      assert_equal transaction_ids, log_entry.metadata["requested_transaction_ids"]
      assert_equal categorized_transaction_ids, log_entry.metadata["categorized_transaction_ids"]
      assert_equal categorized_transaction_ids.size, log_entry.metadata["modified_count"]
    end

    AutoCategorization = Provider::LlmConcept::AutoCategorization
end
