require "test_helper"

class BreadcrumbableTest < ActiveSupport::TestCase
  test "system health breadcrumbs" do
    controller = Admin::SystemHealthController.new
    controller.set_request!(ActionDispatch::TestRequest.create)

    assert_equal "System Health", I18n.t("breadcrumbs.system_health", raise: true)
    assert_equal [ [ "Home", "/" ], [ "System Health", nil ] ], controller.send(:breadcrumbs)
  end
end
