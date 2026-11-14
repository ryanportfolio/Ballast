require "test_helper"

class CustomConfirmTest < ActiveSupport::TestCase
  # `confirm_dialog_controller` renders `body` with textContent, so a record
  # named "<img src=x onerror=…>" shows as that text. Escaping it here as well
  # would print the entities: "rock &amp; roll" instead of "rock & roll".
  test "passes the resource name through as text" do
    assert_includes CustomConfirm.for_resource_deletion("<img src=x onerror=alert(1)>").to_data_attribute[:body],
      "<img src=x onerror=alert(1)>"
    assert_includes CustomConfirm.for_resource_deletion("Rock & Roll").to_data_attribute[:body], "rock & roll"
  end

  test "keeps the English copy the hardcoded strings produced" do
    data = CustomConfirm.for_resource_deletion("rule").to_data_attribute

    assert_equal "Delete Rule?", data[:title]
    assert_equal "Are you sure you want to delete rule? This is not reversible.", data[:body]
    assert_equal "Delete Rule", data[:confirmText]
  end

  test "high severity picks the destructive button variant" do
    assert_equal "destructive", CustomConfirm.for_resource_deletion("rule", high_severity: true).to_data_attribute[:variant]
    assert_equal "outline-destructive", CustomConfirm.for_resource_deletion("rule").to_data_attribute[:variant]
  end
end
