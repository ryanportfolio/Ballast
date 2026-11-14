require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
  end

  test "gets index" do
    get imports_url

    assert_response :success

    @user.family.imports.ordered.each do |import|
      assert_select "#" + dom_id(import), count: 1
    end
  end

  test "gets new" do
    get new_import_url

    assert_response :success

    assert_select "turbo-frame#modal"
    %w[import_transactions import_portfolio import_accounts import_categories import_merchants import_rules].each do |key|
      assert_select "button", text: I18n.t("imports.new.#{key}"), count: 1
    end
    assert_select "input[type=file]", count: 0
  end

  # DS::Button with an href renders button_to, which POSTs unless given a
  # method. revert only routes PUT, so Try again hit a routing error.
  test "try again on a failed revert PUTs to revert" do
    import = imports(:transaction)
    import.update_columns(status: "revert_failed")
    TransactionImport.any_instance.stubs(uploaded?: true, publishable?: true)

    get import_url(import)

    assert_response :success
    assert_select "form[action=?]", revert_import_path(import) do
      assert_select "input[name=_method][value=put]"
    end
  end

  # POSTing to imports_path is create, which needs import params.
  test "back to imports on an empty import is a link to the imports page" do
    import = imports(:transaction)
    TransactionImport.any_instance.stubs(uploaded?: true, publishable?: true)

    get import_url(import)

    assert_response :success
    assert_select "a[href=?]", imports_path, text: I18n.t("imports.ready.back_to_imports")
    assert_select "form[action=?]", imports_path, count: 0
  end

  test "cancel marks a lost import as failed" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 2.hours.ago)

    post cancel_import_path(import)

    assert_redirected_to imports_path
    assert_equal "failed", import.reload.status
    assert_equal Import.lost_error_message, import.error
  end

  test "cancel refuses an import that is not presumed lost" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 5.minutes.ago)

    post cancel_import_path(import)

    assert_equal I18n.t("imports.cancel.not_cancellable"), flash[:alert]
    assert_equal "importing", import.reload.status
  end

  test "cannot cancel another family's import" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 2.hours.ago)

    sign_in users(:empty)

    post cancel_import_path(import)

    assert_response :not_found
    assert_equal "importing", import.reload.status
  end

  test "shows disabled account-dependent imports when family has no accounts" do
    sign_in users(:empty)

    get new_import_url

    assert_response :success
    assert_select "button", text: "Import accounts"
    assert_select "button", text: "Import transactions", count: 0
    assert_select "button", text: "Import investments", count: 0
    assert_select "span", text: "Import accounts first to unlock this option.", count: 2
    assert_select "div[aria-disabled=true]", count: 2
  end

  test "creates import" do
    assert_difference "Import.count", 1 do
      post imports_url, params: {
        import: {
          type: "TransactionImport"
        }
      }
    end

    assert_redirected_to import_upload_url(Import.all.ordered.first)
  end

  test "create with an empty request body redirects back with an alert" do
    assert_no_difference "Import.count" do
      post imports_url
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.missing_upload"), flash[:alert]
  end

  test "publishes import" do
    import = imports(:transaction)

    TransactionImport.any_instance.expects(:publish_later).once

    post publish_import_url(import)

    assert_equal "Your import has started in the background.", flash[:notice]
    assert_redirected_to import_path(import)
  end

  test "member can publish import targeting a family account" do
    import = imports(:transaction)
    import.update!(account: accounts(:depository))
    import.mappings.create!(type: "Import::AccountMapping", key: "Checking", mappable: accounts(:depository))
    TransactionImport.any_instance.expects(:publish_later).once

    sign_in users(:family_member)
    post publish_import_url(import)

    assert_redirected_to import_path(import)
    assert_equal I18n.t("imports.publish.started"), flash[:notice]
  end

  test "destroys import" do
    import = imports(:transaction)

    assert_difference "Import.count", -1 do
      delete import_url(import)
    end

    assert_redirected_to imports_path
  end
end
