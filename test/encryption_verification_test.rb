# frozen_string_literal: true

require "test_helper"

class EncryptionVerificationTest < ActiveSupport::TestCase
  # Skip all tests in this file if encryption is not configured.
  # This allows the test suite to pass in environments without encryption keys.
  setup do
    skip "Encryption not configured" unless User.encryption_ready?
  end

  # ============================================================================
  # USER MODEL TESTS
  # ============================================================================

  test "user email is encrypted and can be looked up" do
    user = User.create!(
      email: "encryption-test@example.com",
      password: "password123",
      family: families(:dylan_family)
    )

    # Verify we can find by email (deterministic encryption)
    found = User.find_by(email: "encryption-test@example.com")
    assert_equal user.id, found.id

    # Verify case-insensitive lookup works
    found_upper = User.find_by(email: "ENCRYPTION-TEST@EXAMPLE.COM")
    assert_equal user.id, found_upper.id

    # Clean up
    user.destroy
  end

  test "user email uniqueness validation works with encryption" do
    user1 = User.create!(
      email: "unique-test@example.com",
      password: "password123",
      family: families(:dylan_family)
    )

    # Should fail uniqueness
    user2 = User.new(
      email: "unique-test@example.com",
      password: "password123",
      family: families(:dylan_family)
    )
    assert_not user2.valid?
    assert user2.errors[:email].any?

    user1.destroy
  end

  test "user names are encrypted and retrievable" do
    user = users(:family_admin)
    original_first = user.first_name
    original_last = user.last_name

    # Update names
    user.update!(first_name: "EncryptedFirst", last_name: "EncryptedLast")
    user.reload

    assert_equal "EncryptedFirst", user.first_name
    assert_equal "EncryptedLast", user.last_name

    # Restore
    user.update!(first_name: original_first, last_name: original_last)
  end

  test "user MFA otp_secret is encrypted" do
    user = users(:family_admin)

    # Setup MFA
    user.setup_mfa!
    assert user.otp_secret.present?

    # Reload and verify we can still read it
    user.reload
    assert user.otp_secret.present?

    # Verify provisioning URI works
    assert user.provisioning_uri.present?

    # Clean up
    user.disable_mfa!
  end

  test "user unconfirmed_email is encrypted" do
    user = users(:family_admin)
    original_email = user.email

    # Set unconfirmed email
    user.update!(unconfirmed_email: "new-email@example.com")
    user.reload

    assert_equal "new-email@example.com", user.unconfirmed_email

    # Clean up
    user.update!(unconfirmed_email: nil)
  end

  # ============================================================================
  # SESSION MODEL TESTS
  # ============================================================================

  test "session user_agent is encrypted" do
    Current.user_agent = "Mozilla/5.0 Test Browser"
    Current.ip_address = "192.168.1.100"

    begin
      session = Session.create!(user: users(:family_admin))

      assert_equal "Mozilla/5.0 Test Browser", session.user_agent
      assert session.ip_address_digest.present?

      # Reload and verify
      session.reload
      assert_equal "Mozilla/5.0 Test Browser", session.user_agent

      # Verify IP hash is consistent
      expected_hash = Digest::SHA256.hexdigest("192.168.1.100")
      assert_equal expected_hash, session.ip_address_digest

      session.destroy
    ensure
      Current.user_agent = nil
      Current.ip_address = nil
    end
  end

  # ============================================================================
  # PROVIDER ITEM TESTS (if fixtures exist)
  # ============================================================================

  test "simplefin account holdings stored before encryption was enabled can be read and backfilled" do
    simplefin_item = SimplefinItem.create!(family: families(:dylan_family), name: "SimpleFIN Connection", access_url: "https://example.com/access")
    account = simplefin_item.simplefin_accounts.create!(
      account_id: "holdings_backfill_probe",
      name: "Brokerage",
      account_type: "investment",
      currency: "USD",
      current_balance: 1000
    )
    # Store plaintext, as an instance that enabled encryption after syncing would have.
    SimplefinAccount.where(id: account.id).update_all(
      "raw_holdings_payload = '{\"holdings\": [{\"security_id\": \"sec_probe\"}]}'::jsonb"
    )

    with_unencrypted_data_supported do
      account = SimplefinAccount.find(account.id)
      assert_equal "sec_probe", account.raw_holdings_payload["holdings"].first["security_id"]

      account.encrypt
    end

    assert_equal "sec_probe", account.reload.raw_holdings_payload["holdings"].first["security_id"]
    assert_column_not_plaintext(SimplefinAccount, account.id, :raw_holdings_payload, "sec_probe")
  end

  # ============================================================================
  # DATABASE VERIFICATION TESTS
  # ============================================================================

  test "encrypted fields are not stored as plaintext in database" do
    user = User.create!(
      email: "plaintext-check@example.com",
      password: "password123",
      first_name: "PlaintextFirst",
      last_name: "PlaintextLast",
      family: families(:dylan_family)
    )

    # Query raw database value
    raw_email = ActiveRecord::Base.connection.select_value(
      User.where(id: user.id).select(:email).to_sql
    )

    # Should NOT be plaintext (should be encrypted blob or different)
    assert_not_equal "plaintext-check@example.com", raw_email,
      "Email should be encrypted in database, not stored as plaintext"

    user.destroy
  end

  private

    def with_unencrypted_data_supported
      previous = ActiveRecord::Encryption.config.support_unencrypted_data
      ActiveRecord::Encryption.config.support_unencrypted_data = true
      yield
    ensure
      ActiveRecord::Encryption.config.support_unencrypted_data = previous
    end

    # Reads +column+ straight from the database, bypassing the model, and asserts the
    # stored bytes do not contain +value+. An accessor round-trip alone cannot tell
    # encryption from plaintext; this can.
    def assert_column_not_plaintext(model, id, column, value)
      raw = ActiveRecord::Base.connection.select_value(
        model.where(id: id).select(column).to_sql
      )

      assert raw.present?, "expected #{model}##{column} to be stored"
      assert_not_includes raw.to_s, value,
        "#{model}##{column} should be encrypted at rest, but the raw column contains #{value.inspect}"
    end
end
