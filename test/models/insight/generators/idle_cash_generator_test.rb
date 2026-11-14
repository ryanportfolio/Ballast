require "test_helper"

class Insight::Generators::IdleCashGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # An untouched Depository account with 5,000 USD.
    @account = accounts(:depository)
    Entry.where(account: @account).delete_all
  end

  test "nudges about an idle account" do
    assert_includes nudged_account_ids, @account.id
  end

  private
    def nudged_account_ids
      Insight::Generators::IdleCashGenerator.new(@family).generate.map { |insight| insight.metadata[:account_id] }
    end
end
