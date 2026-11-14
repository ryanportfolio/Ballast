require "test_helper"

class Family::MerchantMatcherRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = Family.create!(name: "Merchant matcher rule family")
    @account = @family.accounts.create!(name: "Rules test", balance: 100, currency: "USD", accountable: Depository.new)
    @netflix = @family.merchants.create!(name: "Netflix")
    @tag = @family.tags.create!(name: "Review")
  end

  test "a new family gets the matcher at the top of its rules, on" do
    rules = @family.rules.ordered.includes(:actions)

    assert_equal [ [ "Merchant matcher", 1, true, "fill_similar_merchants" ] ],
                 rules.map { |rule| [ rule.name, rule.position, rule.active?, rule.actions.sole.action_type ] }
    assert rules.all? { |rule| rule.conditions.none? }
  end

  test "an added matcher rule goes in at the top, the others moving down" do
    mine = name_rule("Mine", "Netflix")
    @family.rules.where.not(id: mine.id).destroy_all

    @family.add_merchant_matcher_rule!

    assert_equal [ "Merchant matcher", "Mine" ], @family.rules.ordered.map(&:name)
    assert_equal 1, @family.rules.ordered.first.position
    assert_operator mine.reload.position, :>, 1
  end

  test "applying a rule below it runs the matcher first" do
    2.times { create_transaction(account: @account, name: "NETFLIX.COM 8812", merchant: @netflix) }
    transaction = create_transaction(account: @account, name: "Netflix com 1203").transaction
    tagging = name_rule("Tag Netflix", "Netflix")

    RuleJob.perform_now(tagging)

    assert_equal @netflix, transaction.reload.merchant
    assert_includes transaction.tags, @tag
  end

  private
    def name_rule(name, match)
      @family.rules.create!(name: name, resource_type: "transaction", active: true,
                            conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
                            actions: [ Rule::Action.new(action_type: "set_transaction_tags", value: [ @tag.id ]) ])
    end
end
