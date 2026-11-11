require "test_helper"

class OnboardableTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:empty)
    @user.family.subscription.destroy
  end

  test "must complete onboarding before any other action" do
    @user.update!(onboarded_at: nil)

    get root_path
    assert_redirected_to onboarding_path
  end

  # Ballast never bills: an onboarded household without a subscription row
  # reaches the dashboard in both app modes, with no trial or upgrade redirect.
  test "onboarded user without a subscription can visit dashboard" do
    @user.update!(onboarded_at: 1.day.ago)

    get root_path
    assert_response :success

    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    get root_path
    assert_response :success
  end
end
