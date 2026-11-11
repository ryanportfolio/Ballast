require "application_system_test_case"

class AdminUserRemovalsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @admin = users(:sure_support_staff)
    @target = users(:family_member)
    @target_email = @target.email
  end

  test "super admin confirms removal and the user loses access" do
    sign_in @admin
    visit admin_users_path

    find("details", text: @target.family.name).find("summary").click

    within find("tr", text: @target_email) do
      find("button[aria-haspopup='dialog']").click
    end
    click_on "Delete User"

    within "dialog[open]" do
      assert_text "This immediately revokes access"
      fill_in "User email", with: @target_email
      click_on "Permanently remove user"
    end

    assert_text "User access revoked and permanent deletion scheduled."
    assert_not @target.reload.active?
    assert_empty @target.sessions
  end
end
