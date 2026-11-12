require "test_helper"

class FamilyResetJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "resets family data successfully" do
    initial_account_count = @family.accounts.count
    initial_category_count = @family.categories.count

    # Family should have existing data
    assert initial_account_count > 0
    assert initial_category_count > 0
    assert @family.imports.count > 0

    FamilyResetJob.perform_now(@family)

    # All data should be removed
    assert_equal 0, @family.accounts.reload.count
    assert_equal 0, @family.categories.reload.count
    assert_equal 0, @family.imports.reload.count
  end

  test "reset leaves another family's imports untouched" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_category = other_family.categories.create!(name: "Other Category")
    other_import = other_family.imports.create!(type: "TransactionImport")

    FamilyResetJob.perform_now(@family)

    assert Import.exists?(other_import.id)
    assert Category.exists?(other_category.id)
  end
end
