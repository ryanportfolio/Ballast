require "test_helper"

class PropertyTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:property)
    @property = @account.property
  end

  # Valuations labelled by Sure's removed property valuation providers keep
  # their name in the database; a later manual edit goes back to the default.
  test "a later manual edit on the same day drops an old provider label" do
    @account.set_current_balance(560_000)
    entry = @account.entries.valuations.find_by(date: Date.current)
    entry.update!(name: "Provider valuation")

    @account.update_reconciliation(entry, balance: 570_000, date: Date.current)

    assert_equal "Manual value update", entry.reload.name
    assert_equal 570_000, entry.amount
  end
end
