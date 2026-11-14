require "test_helper"

class ValuationTest < ActiveSupport::TestCase
  test "renders generated valuation names from the translation" do
    entry = Entry.new(name: "Manual value update", account: accounts(:investment))
    valuation = Valuation.new(kind: "reconciliation")

    assert_equal "Manual value update", valuation.display_name(entry)
  end

  test "preserves custom valuation names when rendering" do
    entry = Entry.new(name: "Réévaluation annuelle", account: accounts(:investment))
    valuation = Valuation.new(kind: "reconciliation")

    assert_equal "Réévaluation annuelle", valuation.display_name(entry)
  end
end
