require "test_helper"

class AccountTest < ActiveSupport::TestCase
  include SyncableInterfaceTest, EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @account = @syncable = accounts(:depository)
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
  end

  test "can destroy" do
    assert_difference "Account.count", -1 do
      @account.destroy
    end
  end

  test "a destroy that raises leaves a pending_deletion account disabled" do
    @account.mark_for_deletion!
    @account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    error = assert_raises(StandardError) { @account.destroy }

    assert_equal "destroy failed", error.message
    assert_equal "disabled", @account.reload.status
  end

  test "a disabled account can be scheduled for deletion again after a failed destroy" do
    @account.mark_for_deletion!
    @account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")
    assert_raises(StandardError) { @account.destroy }
    @account.unstub(:cleanup_transfers)
    @account.reload

    assert_enqueued_with(job: DestroyJob, args: [ @account ]) do
      @account.destroy_later
    end
    assert_equal "pending_deletion", @account.reload.status
  end

  test "a failed direct destroy still disables an active account" do
    assert @account.active?
    @account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    assert_raises(StandardError) { @account.destroy }

    assert_equal "disabled", @account.reload.status
  end

  test "the failed-destroy restore leaves a status written since the record was loaded" do
    @account.mark_for_deletion!
    Account.where(id: @account.id).update_all(status: "active")

    @account.restore_after_failed_destroy

    assert @account.pending_deletion?
    assert_equal "active", @account.reload.status
  end

  test "disable from active is unchanged" do
    assert @account.active?

    @account.disable!

    assert_equal "disabled", @account.reload.status
  end

  test "no event other than the failed-deletion recovery leaves pending_deletion" do
    @account.mark_for_deletion!

    assert_not @account.may_activate?
    assert_not @account.may_enable?
    assert_not @account.may_disable?
    assert_not @account.may_mark_for_deletion?
    permitted = @account.aasm.events(permitted: true).map(&:name)
    assert_equal [ :restore_after_failed_deletion ], permitted
  end

  test "the failed-deletion recovery only fires from pending_deletion" do
    assert @account.active?
    assert_not @account.aasm.may_fire_event?(:restore_after_failed_deletion)

    @account.disable!
    assert_not @account.aasm.may_fire_event?(:restore_after_failed_deletion)
  end

  # disabled_at is the net-worth cutoff for a disabled account
  # (NetWorthSeriesBuilder, NetWorthBreakdownSeriesBuilder). A failed delete
  # must not move it to the failure, which would count the account's balances
  # for the whole time it was already disabled.
  test "a failed destroy of a disabled account keeps its original disabled_at" do
    disabled_at = 40.days.ago.change(usec: 0)
    @account.update_columns(status: "disabled", disabled_at: disabled_at)
    @account.mark_for_deletion!
    @account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    assert_raises(StandardError) { @account.destroy }

    @account.reload
    assert_equal "disabled", @account.status
    assert_equal disabled_at, @account.disabled_at
  end

  # The other side: an account deleted from active has no cutoff yet, so the
  # failure is when it stopped counting. One disabled and enabled again earlier
  # must not inherit that old cutoff.
  test "a failed destroy of an account that was active stamps disabled_at at the failure" do
    @account.disable!
    @account.enable!
    @account.mark_for_deletion!
    @account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    failed_at = 3.days.from_now.change(usec: 0)
    travel_to(failed_at) { assert_raises(StandardError) { @account.destroy } }

    @account.reload
    assert_equal "disabled", @account.status
    assert_equal failed_at, @account.disabled_at
  end

  # An account disabled and enabled again before enable cleared disabled_at
  # still carries that date while active or draft. Deleting it must drop the
  # stale date, so a failed destroy stamps the failure instead of reviving it
  # as the account's net-worth cutoff.
  test "a failed destroy of an active or draft account with a stale disabled_at stamps the failure" do
    stale = 1.year.ago.change(usec: 0)
    failed_at = 3.days.from_now.change(usec: 0)

    results = %w[active draft].index_with do |status|
      @account.update_columns(status: status, disabled_at: stale)
      @account.reload.mark_for_deletion!
      @account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

      travel_to(failed_at) { assert_raises(StandardError) { @account.destroy } }
      @account.unstub(:cleanup_transfers)

      @account.reload
      [ @account.status, @account.disabled_at ]
    end

    assert_equal({ "active" => [ "disabled", failed_at ], "draft" => [ "disabled", failed_at ] }, results)
  end

  test "marking an active or draft account for deletion clears a stale disabled_at" do
    results = %w[active draft].index_with do |status|
      @account.update_columns(status: status, disabled_at: 1.year.ago)
      @account.reload.mark_for_deletion!
      @account.reload.disabled_at
    end

    assert_equal({ "active" => nil, "draft" => nil }, results)
  end

  test "marking a disabled account for deletion keeps its disabled_at" do
    disabled_at = 40.days.ago.change(usec: 0)
    @account.update_columns(status: "disabled", disabled_at: disabled_at)

    @account.reload.mark_for_deletion!

    assert_equal disabled_at, @account.reload.disabled_at
  end

  test "enabling an account clears disabled_at" do
    @account.disable!
    assert_not_nil @account.reload.disabled_at

    @account.enable!
    assert_nil @account.reload.disabled_at

    @account.disable!
    @account.activate!
    assert_nil @account.reload.disabled_at
  end

  test "set_current_balance schedules an account sync by default" do
    @account.expects(:sync_later).once

    assert @account.set_current_balance(1234).success?
  end

  test "set_current_balance skips the account sync when the caller schedules it" do
    @account.expects(:sync_later).never

    assert @account.set_current_balance(1234, schedule_sync: false).success?
    assert_equal 1234, @account.reload.current_anchor_balance
  end

  test "create_and_sync calls sync_later by default" do
    Account.any_instance.expects(:sync_later).once

    account = Account.create_and_sync({
      family: @family,
      name: "Test Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    assert account.persisted?
    assert_equal "USD", account.currency
    assert_equal 100, account.balance
  end

  test "create_and_sync skips sync_later when skip_initial_sync is true" do
    Account.any_instance.expects(:sync_later).never

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Linked Account",
        balance: 500,
        currency: "EUR",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )

    assert account.persisted?
    assert_equal "EUR", account.currency
    assert_equal 500, account.balance
  end

  test "create_and_sync creates opening anchor with correct currency" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Test Account",
        balance: 1000,
        currency: "GBP",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )

    opening_anchor = account.valuations.opening_anchor.first
    assert_not_nil opening_anchor
    assert_equal "GBP", opening_anchor.entry.currency
    assert_equal 1000, opening_anchor.entry.amount
  end

  test "create_and_sync keeps the entered current balance when it differs from the opening balance" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 20_000, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 20_000, account.valuations.opening_anchor.first.entry.amount
    # Without a today anchor, the initial sync would walk forward from the
    # opening valuation and overwrite the entered 8,000 with 20,000.
    today_valuation = account.entries.valuations.find_by(date: Date.current)
    assert_not_nil today_valuation
    assert_equal 8_000, today_valuation.amount
  end

  test "create_and_sync leaves the opening anchor alone when the opening balance date is today" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 20_000, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true,
      opening_balance_date: Date.current
    )

    # Both balances land on the same day, so today's balance cannot be
    # anchored without reusing (and overwriting) the opening anchor.
    valuations = account.entries.valuations.where(date: Date.current)
    assert_equal 1, valuations.count
    assert_equal 20_000, valuations.first.amount
    assert_equal "opening_anchor", valuations.first.entryable.kind
  end

  test "create_and_sync treats a blank initial balance as absent" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: "", rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 8_000, account.valuations.opening_anchor.first.entry.amount
    assert_nil account.entries.valuations.find_by(date: Date.current)
  end

  test "create_and_sync treats a zero initial balance as a real opening balance" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 0, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 0, account.valuations.opening_anchor.first.entry.amount
    assert_equal 8_000, account.entries.valuations.find_by(date: Date.current)&.amount
  end

  # #3383: only a loan's start date moves the opening anchor.
  test "create_and_sync dates a loan's opening anchor on its start date" do
    Account.any_instance.stubs(:sync_later)
    opening_balance_date = Date.current - 2.years

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Mortgage",
        balance: 399_600,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 400_000, start_date: Date.new(2020, 1, 15),
                                  rate_type: "fixed", interest_rate: 5, term_months: 360 }
      },
      skip_initial_sync: true,
      opening_balance_date: opening_balance_date
    )

    assert_equal Date.new(2020, 1, 15), account.valuations.opening_anchor.first.entry.date
    assert_equal 399_600, account.entries.valuations.find_by(date: Date.current)&.amount
  end

  # The anchor is dated on the start date only because Loan rejects a future
  # one: an anchor after today would skip today's reconciliation and leave the
  # account with no balance for today.
  # Entry rejects a date on or before Entry.min_supported_date, so a loan drawn
  # down that long ago keeps the form's opening date, as before the start date
  # moved the anchor. Both sides of the boundary.
  test "a loan whose start date is on the earliest supported entry date keeps the form's opening date" do
    Account.any_instance.stubs(:sync_later)
    opening_balance_date = Date.current - 2.years
    start_date = Entry.min_supported_date

    account = create_loan_with_start_date(start_date, opening_balance_date)

    assert_equal start_date, account.accountable.start_date
    assert_equal opening_balance_date, account.valuations.opening_anchor.first.entry.date
  end

  test "a loan started the day after the earliest supported date is anchored on its start date" do
    Account.any_instance.stubs(:sync_later)
    start_date = Entry.min_supported_date + 1.day

    account = create_loan_with_start_date(start_date, Date.current - 2.years)

    assert_equal start_date, account.valuations.opening_anchor.first.entry.date
  end

  test "create_and_sync rejects a loan with a future start date and writes no anchor" do
    Account.any_instance.stubs(:sync_later)

    assert_no_difference [ "Account.count", "Entry.count" ] do
      assert_raises ActiveRecord::RecordInvalid do
        Account.create_and_sync(
          {
            family: @family,
            name: "Mortgage",
            balance: 399_600,
            currency: "USD",
            accountable_type: "Loan",
            accountable_attributes: { initial_balance: 400_000, start_date: Date.current + 1.month,
                                      rate_type: "fixed", interest_rate: 5, term_months: 360 }
          },
          skip_initial_sync: true,
          opening_balance_date: Date.current - 3.years
        )
      end
    end
  end

  test "create_and_sync keeps a depository account's opening balance date" do
    Account.any_instance.stubs(:sync_later)
    opening_balance_date = Date.new(2020, 1, 15)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Checking",
        balance: 1_000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true,
      opening_balance_date: opening_balance_date
    )

    assert_equal opening_balance_date, account.valuations.opening_anchor.first.entry.date
  end

  test "a provider-created loan keeps the default opening date" do
    item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: item, name: "My Loan", account_id: "acct_424",
      currency: "USD", account_type: "loan", current_balance: 5_000
    )

    account = Account.create_from_simplefin_account(simplefin_account, "Loan")

    assert_nil account.accountable.start_date
    assert_equal 2.years.ago.to_date, account.valuations.opening_anchor.first.entry.date
    assert_equal 1, account.entries.valuations.count
  end

  test "create_and_sync uses provided opening balance date" do
    Account.any_instance.stubs(:sync_later)
    opening_date = Time.zone.today

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Test Account",
        balance: 1000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true,
      opening_balance_date: opening_date
    )

    opening_anchor = account.valuations.opening_anchor.first
    assert_equal opening_date, opening_anchor.entry.date
  end

  test "subtype set as a top-level account attribute persists on create" do
    Account.any_instance.stubs(:sync_later)

    # Mirrors the create flow: the form submits `account[subtype]` as a
    # top-level attribute (not nested under accountable_attributes). The
    # accountable does not exist yet, so the delegating writer must build it.
    account = Account.create_and_sync({
      family: @family,
      name: "Savings Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      subtype: "savings"
    })

    assert account.persisted?
    assert_equal "savings", account.reload.subtype
    assert_equal "savings", account.accountable.subtype
  end

  test "subtype assigned before accountable is built is not dropped" do
    account = Account.new
    account.accountable_type = "Depository"
    account.subtype = "checking"

    assert_not_nil account.accountable
    assert_equal "checking", account.subtype
  end

  test "subtype assigned before accountable_type is not dropped" do
    # The real controller path: strong-params `permit` preserves filter order,
    # and `account_params` lists `:subtype` before `:accountable_type`, so the
    # subtype writer runs while the type is still unknown.
    account = Account.new
    account.subtype = "savings"
    account.accountable_type = "Depository"

    assert_not_nil account.accountable
    assert_equal "savings", account.subtype
    assert_equal "savings", account.accountable.subtype
  end

  test "subtype persists on create when attributes arrive in permit order" do
    Account.any_instance.stubs(:sync_later)

    # Mirrors `account_params`: `permit` yields keys in filter order, so the
    # create hash carries `subtype` before `accountable_type` — the ordering
    # that previously dropped the subtype on create.
    account = Account.create_and_sync({
      family: @family,
      name: "Savings Account",
      balance: 100,
      subtype: "savings",
      currency: "USD",
      accountable_type: "Depository"
    })

    assert account.persisted?
    assert_equal "savings", account.reload.subtype
    assert_equal "savings", account.accountable.subtype
  end

  test "accountable display names expose singular and group contexts" do
    assert_equal "Investment", Investment.singular_display_name
    assert_equal "Investments", Investment.display_name
    assert_equal "Cash", Depository.singular_display_name
    assert_equal "Cash", Depository.display_name
  end

  test "gets short/long subtype label" do
    investment = Investment.new(subtype: "hsa")
    account = @family.accounts.create!(
      name: "Test Investment",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_equal "HSA", account.short_subtype_label
    assert_equal "Health Savings Account", account.long_subtype_label

    # Test with nil subtype
    account.accountable.update!(subtype: nil)
    assert_equal "Investments", account.short_subtype_label
    assert_equal "Investments", account.long_subtype_label
  end

  # Tax treatment tests (TaxTreatable concern)

  test "tax_treatment delegates to accountable for Investment" do
    investment = Investment.new(subtype: "401k")
    account = @family.accounts.create!(
      name: "Test 401k",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_equal :tax_deferred, account.tax_treatment
    assert_equal I18n.t("accounts.tax_treatments.tax_deferred"), account.tax_treatment_label
  end

  test "tax_treatment delegates to accountable for Crypto" do
    crypto = Crypto.new(tax_treatment: :taxable)
    account = @family.accounts.create!(
      name: "Test Crypto",
      balance: 500,
      currency: "USD",
      accountable: crypto
    )

    assert_equal :taxable, account.tax_treatment
    assert_equal I18n.t("accounts.tax_treatments.taxable"), account.tax_treatment_label
  end

  test "tax_treatment returns nil for non-HSA depository accounts" do
    # Depository exposes a `tax_treatment` method so HSA cash flips
    # tax-advantaged, but non-HSA subtypes (checking, savings, cd,
    # money_market) return nil. nil still reads as taxable via `taxable?`,
    # and keeps `tax_treatment.present?` false so the header tax badge does
    # not appear on ordinary bank accounts that never displayed it before.
    assert_nil @account.tax_treatment
    assert_nil @account.tax_treatment_label
    assert_not @account.tax_treatment.present?
    assert @account.taxable?
  end

  test "tax_treatment returns nil for accountables that do not implement it" do
    # CreditCard / Loan / Property / OtherAsset / OtherLiability do not
    # implement `tax_treatment`, so the `TaxTreatable#respond_to?` short-
    # circuit still returns nil for them.
    credit_card_account = @family.accounts.create!(
      name: "Test Credit Card",
      balance: 100,
      currency: "USD",
      accountable: CreditCard.new
    )

    assert_nil credit_card_account.tax_treatment
    assert_nil credit_card_account.tax_treatment_label
  end

  test "tax_advantaged? returns true for tax-advantaged accounts" do
    investment = Investment.new(subtype: "401k")
    account = @family.accounts.create!(
      name: "Test 401k",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert account.tax_advantaged?
    assert_not account.taxable?
  end

  test "tax_advantaged? returns true for HSA depository accounts" do
    hsa_depository = @family.accounts.create!(
      name: "Fidelity HSA Cash",
      balance: 3_000,
      currency: "USD",
      accountable: Depository.new(subtype: "hsa")
    )

    assert_equal :tax_advantaged, hsa_depository.tax_treatment
    assert hsa_depository.tax_advantaged?
    assert_not hsa_depository.taxable?
  end

  test "tax_advantaged? returns false for taxable accounts" do
    investment = Investment.new(subtype: "brokerage")
    account = @family.accounts.create!(
      name: "Test Brokerage",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_not account.tax_advantaged?
    assert account.taxable?
  end

  test "taxable? returns true for non-HSA depository accounts" do
    # `@account` is the checking depository fixture; `tax_treatment` is
    # `nil` (no subtype override), which `taxable?` reads as true.
    assert @account.taxable?
    assert_not @account.tax_advantaged?
  end

  test "destroying account purges attached logo" do
    @account.logo.attach(
      io: StringIO.new("fake-logo-content"),
      filename: "logo.png",
      content_type: "image/png"
    )

    attachment_id = @account.logo.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      @account.destroy!
    end

    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "destroying account moves linked statements to inbox after commit" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(match_confidence: 0.8)

    @account.destroy!

    statement.reload
    assert_nil statement.account_id
    assert_equal "unmatched", statement.review_status
    assert_nil statement.match_confidence
  end

  test "rolled back account destroy keeps linked statements unchanged" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(match_confidence: 0.8)

    Account.transaction do
      @account.destroy!
      raise ActiveRecord::Rollback
    end

    statement.reload
    assert Account.exists?(@account.id)
    assert_equal @account.id, statement.account_id
    assert_equal "linked", statement.review_status
    assert_equal 0.8.to_d, statement.match_confidence
  end

  test "every member of a family reaches every account of that family and none of another" do
    outsider = users(:empty)
    family_ids = @family.accounts.pluck(:id).sort

    assert_equal family_ids, Account.accessible_by(@member).pluck(:id).sort
    assert_equal family_ids, Account.writable_by(@member).pluck(:id).sort
    assert_not_includes Account.accessible_by(outsider).pluck(:id), @account.id
    assert_not_includes Account.writable_by(outsider).pluck(:id), @account.id

    assert @account.accessible_by?(@member)
    assert_not @account.accessible_by?(outsider)
  end

  test "included_in_reports scope excludes accounts marked as exclude_from_reports" do
    included = @family.accounts.create! name: "Included", balance: 100, currency: "USD", accountable: Depository.new
    excluded = @family.accounts.create! name: "Excluded", balance: 200, currency: "USD", accountable: Depository.new, exclude_from_reports: true

    results = @family.accounts.included_in_reports
    assert_includes results, included
    assert_not_includes results, excluded
  end

  test "current_holdings prefers latest provider snapshot holdings across currencies" do
    account = @family.accounts.create!(
      name: "Linked Brokerage",
      balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )

    simplefin_item = @family.simplefin_items.create!(name: "SimpleFIN", access_url: "https://example.com/access")
    simplefin_account = simplefin_item.simplefin_accounts.create!(name: "Brokerage", currency: "USD", account_type: "investment", current_balance: 0)
    account_provider = AccountProvider.create!(account: account, provider: simplefin_account)

    eur_security = Security.create!(ticker: "ASML", name: "ASML")
    chf_security = Security.create!(ticker: "NOVN", name: "Novartis")

    provider_holding = account.holdings.create!(
      security: eur_security,
      date: Date.current,
      qty: 2,
      price: 500,
      amount: 1000,
      currency: "EUR",
      account_provider: account_provider,
      cost_basis: 450
    )

    account.holdings.create!(
      security: eur_security,
      date: Date.current,
      qty: 2,
      price: 540,
      amount: 1080,
      currency: "USD"
    )

    second_provider_holding = account.holdings.create!(
      security: chf_security,
      date: Date.current,
      qty: 3,
      price: 90,
      amount: 270,
      currency: "CHF",
      account_provider: account_provider,
      cost_basis: 80
    )

    assert_equal [ provider_holding.id, second_provider_holding.id ].sort, account.current_holdings.pluck(:id).sort
    assert_equal %w[CHF EUR], account.current_holdings.pluck(:currency).sort
  end

  test "on account destroyed cascade transfer destroyed" do
    outflow_account = @family.accounts.create!({
      name: "test_account_outflow",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })
    inflow_account = @family.accounts.create!({
      name: "test_account_inflow",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    transfer = create_transfer(
      from_account: outflow_account,
      to_account: inflow_account,
      amount: 50
    )

    outflow_transaction = transfer.outflow_transaction

    outflow_transaction.reload
    assert_equal "funds_movement", outflow_transaction.kind

    inflow_account.destroy!

    assert_raises(ActiveRecord::RecordNotFound) { transfer.reload }

    outflow_transaction.reload
    assert_equal "standard", outflow_transaction.kind
  end

  test "cleanup transfers preloads transaction associations" do
    counterparty = @family.accounts.create!(
      name: "Transfer counterparty",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )
    transfers = 3.times.map do |index|
      create_transfer(
        from_account: @account,
        to_account: counterparty,
        amount: 10 + index
      )
    end

    queries = capture_sql_queries { @account.send(:cleanup_transfers) }

    assert_empty queries.grep(/SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" =/)
    assert transfers.all? { |transfer| !Transfer.exists?(transfer.id) }
  end

  test "history_start_date resolves to the earliest of opening anchor, entries, and balances" do
    account = @family.accounts.create!(
      name: "History Test Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    assert_nil account.history_start_date

    anchor_date = 30.days.ago.to_date
    account.set_opening_anchor_balance(balance: 100, date: anchor_date)
    assert_equal anchor_date, account.history_start_date

    earlier_entry_date = 45.days.ago.to_date
    account.entries.create!(
      name: "Past Entry",
      date: earlier_entry_date,
      amount: 50,
      currency: "USD",
      entryable: Transaction.new
    )
    assert_equal earlier_entry_date, account.history_start_date
  end

  test "history_start_date returns nil when account has no opening anchor, entries, or balances" do
    account = @family.accounts.create!(
      name: "Empty History Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    assert_nil account.history_start_date
  end

  test "history_start_date resolves to transaction date when there is no opening valuation" do
    account = @family.accounts.create!(
      name: "Transaction Only Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    trade_date = 2.years.ago.to_date
    account.entries.create!(
      name: "Old Trade",
      date: trade_date,
      amount: 500,
      currency: "USD",
      entryable: Transaction.new
    )

    assert_equal trade_date, account.history_start_date
  end

  test "history_start_date resolves to balance date when there are no entries or opening valuation" do
    account = @family.accounts.create!(
      name: "Balance Only Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    balance_date = 1.year.ago.to_date
    account.balances.create!(
      date: balance_date,
      balance: 1000,
      currency: "USD"
    )

    assert_equal balance_date, account.history_start_date
  end

  test "history_start_date prefers earlier transaction when valuation is added much later" do
    account = @family.accounts.create!(
      name: "Late Valuation Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    trade_date = 2.years.ago.to_date
    account.entries.create!(
      name: "Initial Buy",
      date: trade_date,
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    # Later reconciliation valuation added 6 months ago
    account.set_opening_anchor_balance(balance: 500, date: 6.months.ago.to_date)

    assert_equal trade_date, account.history_start_date
  end

  test "history_start_date handles transaction from 10 years ago" do
    account = @family.accounts.create!(
      name: "Decade Old Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    ten_years_ago = 10.years.ago.to_date
    account.entries.create!(
      name: "Decade Ago Trade",
      date: ten_years_ago,
      amount: 250,
      currency: "USD",
      entryable: Transaction.new
    )

    assert_equal ten_years_ago, account.history_start_date
  end

  test "history_start_date ignores pending transactions" do
    account = @family.accounts.create!(
      name: "Pending Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    account.entries.destroy_all
    account.balances.destroy_all

    posted_date = 5.days.ago.to_date
    account.entries.create!(
      name: "Posted Entry",
      date: posted_date,
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    account.entries.create!(
      name: "Pending Entry",
      date: 10.days.ago.to_date,
      amount: 50,
      currency: "USD",
      entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
    )

    assert_equal posted_date, account.history_start_date
  end

  test "history_start_date on linked investment account resolves to provider activity ignoring default anchor" do
    account = @family.accounts.create!(
      name: "Linked Investment Account",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    link_account_to_simplefin!(account, account_type: "investment")
    assert account.linked?

    default_anchor_date = 2.years.ago.to_date
    account.set_opening_anchor_balance(balance: 0, date: default_anchor_date)

    recent_trade_date = 14.days.ago.to_date
    account.entries.create!(
      name: "Recent Provider Trade",
      date: recent_trade_date,
      amount: 100,
      currency: "USD",
      source: "simplefin",
      entryable: Transaction.new
    )

    assert_equal recent_trade_date, account.history_start_date
  end

  test "history_start_date on linked investment account returns nil when no provider activity exists" do
    account = @family.accounts.create!(
      name: "Fresh Linked Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    link_account_to_simplefin!(account, account_type: "investment")
    assert account.linked?

    default_anchor_date = 2.years.ago.to_date
    account.set_opening_anchor_balance(balance: 0, date: default_anchor_date)

    assert_nil account.history_start_date
  end

  private
    def create_loan_with_start_date(start_date, opening_balance_date)
      Account.create_and_sync(
        {
          family: @family,
          name: "Mortgage",
          balance: 399_600,
          currency: "USD",
          accountable_type: "Loan",
          accountable_attributes: { initial_balance: 400_000, start_date: start_date,
                                    rate_type: "fixed", interest_rate: 5, term_months: 360 }
        },
        skip_initial_sync: true,
        opening_balance_date: opening_balance_date
      )
    end
end
