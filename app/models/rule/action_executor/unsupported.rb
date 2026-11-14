# Stands in for a stored action whose type no executor handles any more (a
# removed feature's action, such as the Bayes classifier's bayes_categorize,
# or an unknown type from an import), like Rule::ConditionFilter::Unsupported
# for conditions. The rule still lists, opens and runs; this action changes
# nothing and claims nothing.
class Rule::ActionExecutor::Unsupported < Rule::ActionExecutor
  def initialize(rule, action_type)
    super(rule)
    @action_type = action_type.to_s
  end

  def key
    @action_type
  end

  def label
    I18n.t("rule.actions.unsupported_label", type: @action_type)
  end

  def reserves_claimed_attributes?
    false
  end

  def execute(_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    Rails.logger.warn(
      "Rule::ActionExecutor::Unsupported executed: " \
      "rule_id=#{rule&.id.inspect} action_type=#{@action_type.inspect}; changing nothing"
    )
    0
  end
end
