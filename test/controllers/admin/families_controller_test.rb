require "test_helper"

class Admin::FamiliesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "destroy deletes an unused family" do
    family = Family.create!(name: "Unused Family")

    assert_difference("Family.count", -1) do
      delete admin_family_url(family)
    end

    assert_redirected_to admin_users_url
  end

  test "destroy does not delete a family with users" do
    family = users(:family_admin).family

    assert_no_difference("Family.count") do
      delete admin_family_url(family)
    end

    assert_redirected_to admin_users_url
  end

  # Ballast has no billing provider to cancel with, so a leftover
  # subscription row goes with its family.
  test "destroy deletes an unused family and its subscription row" do
    family = Family.create!(name: "Subscribed Empty Family")
    family.start_subscription!("sub_admin_cleanup")
    subscription = family.subscription

    assert_difference("Family.count", -1) do
      delete admin_family_url(family)
    end

    assert_redirected_to admin_users_url
    assert_not Subscription.exists?(subscription.id)
  end
end
