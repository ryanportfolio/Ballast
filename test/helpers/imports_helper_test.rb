require "test_helper"

class ImportsHelperTest < ActionView::TestCase
  test "dry run resource labels come from locale keys" do
    keys = %i[transactions accounts categories tags rules merchants]

    keys.each do |key|
      assert_equal I18n.t("imports.dry_run_resources.#{key}"), dry_run_resource(key).label
    end

    keys.map { |key| dry_run_resource(key) }.each do |resource|
      refute_match(/\b(?:text|bg)-[a-z]+-\d{2,3}/, [ resource.text_class, resource.bg_class ].join(" "))
    end
  end
end
