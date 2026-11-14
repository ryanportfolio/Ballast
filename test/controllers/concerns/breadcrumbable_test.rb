require "test_helper"

class BreadcrumbableTest < ActiveSupport::TestCase
  test "default breadcrumbs name the controller" do
    controller = Settings::HostingsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)

    assert_equal "Self-Hosting", I18n.t("breadcrumbs.hostings", raise: true)
    assert_equal [ [ "Home", "/" ], [ "Self-Hosting", nil ] ], controller.send(:breadcrumbs)
  end
end
