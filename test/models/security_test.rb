require "test_helper"

class SecurityTest < ActiveSupport::TestCase
  # Below has 3 example scenarios:
  # 1. Original ticker
  # 2. Duplicate ticker on a different exchange (different market price)
  # 3. "Offline" version of the same ticker (for users not connected to a provider)
  test "classification columns accept nil and every value in the taxonomy" do
    security = securities(:aapl)

    assert_nil security.asset_class
    assert_not security.classification_locked?

    Security::ASSET_CLASSES.each do |asset_class|
      security.asset_class = asset_class
      assert security.valid?, "#{asset_class} should be a valid asset_class"
    end
    Security::ASSET_SUB_CLASSES.each do |sub_class|
      security.asset_sub_class = sub_class
      assert security.valid?, "#{sub_class} should be a valid asset_sub_class"
    end
    Security::CLASSIFICATION_SOURCES.each do |source|
      security.classification_source = source
      assert security.valid?, "#{source} should be a valid classification_source"
    end
  end

  test "classification columns reject values outside the taxonomy" do
    security = securities(:aapl)

    security.asset_class = "stocks"
    assert_not security.valid?
    assert_includes security.errors[:asset_class], "is not included in the list"

    security.asset_class = nil
    security.asset_sub_class = "share"
    assert_not security.valid?

    security.asset_sub_class = nil
    security.classification_source = "guess"
    assert_not security.valid?
  end

  test "the database enforces the classification taxonomy independently of the model" do
    security = securities(:aapl)

    # update_column skips validations, so only the check constraint can object.
    # Each attempt runs in its own savepoint: a failed statement aborts the
    # surrounding transaction, which is the one the test fixture runs in.
    { asset_class: "stocks", asset_sub_class: "share", classification_source: "guess" }.each do |column, value|
      assert_raises(ActiveRecord::StatementInvalid, "#{column}=#{value} should violate the check constraint") do
        Security.transaction(requires_new: true) { security.update_column(column, value) }
      end
    end

    security.update_columns(asset_class: "equity", asset_sub_class: "stock", classification_source: "manual", classification_locked: true)
    assert_equal %w[equity stock manual], security.reload.values_at(:asset_class, :asset_sub_class, :classification_source)
    assert security.classification_locked?
  end

  # The counterpart to the two taxonomy tests: sector and industry are free text
  # ON PURPOSE, because each provider ships its own vocabulary and a constraint
  # would reject a value one of them legitimately returns. That is an absence --
  # of a constraint and of an `inclusion` rule -- and an absence is exactly what
  # no other test here would notice being filled in. Adding either one later
  # breaks classification ingestion for a provider, and the first symptom would
  # be in the provider, not in this file.
  #
  # `region` is deliberately NOT asserted here; see the test below for why the
  # two cases are not the same.
  #
  # Values chosen to be outside any plausible taxonomy and to carry the
  # punctuation real provider strings do, since a normalising validation would
  # pass a tidy string and fail on these.
  test "sector and industry are unconstrained free text" do
    security = securities(:aapl)
    free_text = "Consumer Electronics & Durables -- EMEA/APAC (ex-Japan), 2nd tier"

    security.assign_attributes(sector: free_text, industry: free_text)
    assert security.valid?, "no inclusion validation belongs on these"

    # And no check constraint either, which the model's validations cannot show.
    security.update_columns(sector: free_text, industry: free_text)
    assert_equal [ free_text ] * 2, security.reload.values_at(:sector, :industry)
  end

  # `region` is unconstrained at the DATABASE level for a different reason than
  # sector and industry, and this test protects only that reason. No provider
  # supplies a region -- they supply a country, and the region is derived from
  # it against a list this application owns -- so the vocabulary is closed and
  # a model-level `inclusion` validation is the right enforcement once
  # something writes it. The list belongs in configuration, where widening it
  # should not need a migration, which is why the constraint is not in the
  # schema.
  #
  # So this asserts the missing CHECK constraint and says nothing about model
  # validation: an `inclusion` rule arriving on `region` later is the intended
  # end state, not a regression, and a test that failed when it landed would be
  # asserting the opposite of the design.
  test "region carries no database check constraint so the list can live in configuration" do
    security = securities(:aapl)
    outside_any_list = "Trans-Kuiper Belt, 2nd tier"

    security.update_columns(region: outside_any_list)
    assert_equal outside_any_list, security.reload.region

    assert_nil Security.connection.check_constraints(:securities).find { |c| c.expression.include?("region") },
               "a check constraint on region would move the list out of configuration and into a migration"
  end

  test "the model taxonomy and the database constraint list the same values" do
    constraints = Security.connection.check_constraints(:securities).index_by(&:name)

    {
      "chk_securities_asset_class" => Security::ASSET_CLASSES,
      "chk_securities_asset_sub_class" => Security::ASSET_SUB_CLASSES,
      "chk_securities_classification_source" => Security::CLASSIFICATION_SOURCES
    }.each do |name, values|
      expression = constraints.fetch(name).expression
      # Capture whole quoted literals rather than `[a-z_]+`: a value carrying a
      # digit or a hyphen would not match that class at all, so it would vanish
      # from the scan and fail this test even though the constant and the
      # constraint agree -- a spurious failure every time the taxonomy grows.
      assert_equal values.sort, expression.scan(/'([^']+)'/).flatten.sort,
        "#{name} and the model constant have drifted apart"
    end
  end

  test "can have duplicate tickers if exchange is different" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.create!(ticker: "TEST", exchange_operating_mic: "CBOE")
    offline = Security.create!(ticker: "TEST", exchange_operating_mic: nil)

    assert original.valid?
    assert duplicate.valid?
    assert offline.valid?
  end

  test "cannot have duplicate tickers if exchange is the same" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: "XNAS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "cannot have duplicate tickers if exchange is nil" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: nil)
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: nil)

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "casing is ignored when checking for duplicates" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "tEst", exchange_operating_mic: "xNaS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "canonicalizes WAR to XWAR on save" do
    security = Security.create!(ticker: "KTY", exchange_operating_mic: "WAR")

    assert_equal "XWAR", security.exchange_operating_mic
  end

  test "find_by_ticker_and_exchange upgrades legacy WAR and avoids duplicates" do
    legacy = Security.create!(ticker: "KTY", exchange_operating_mic: "XWAR")
    legacy.update_columns(exchange_operating_mic: "WAR")

    found = Security.find_by_ticker_and_exchange(ticker: "KTY", exchange_operating_mic: "XWAR")

    assert_equal legacy.id, found.id
    assert_equal "XWAR", found.reload.exchange_operating_mic
  end

  test "cash_for lazily creates a per-account synthetic cash security" do
    account = accounts(:investment)

    cash = Security.cash_for(account)

    assert cash.persisted?
    assert cash.cash?
    assert cash.offline?
    assert_equal "Cash", cash.name
    assert_includes cash.ticker, account.id.upcase
  end

  test "cash_for returns the same security on repeated calls" do
    account = accounts(:investment)

    first  = Security.cash_for(account)
    second = Security.cash_for(account)

    assert_equal first.id, second.id
  end

  test "standard scope excludes cash securities" do
    account = accounts(:investment)
    Security.cash_for(account)

    standard_tickers = Security.standard.pluck(:ticker)

    assert_not_includes standard_tickers, "CASH-#{account.id.upcase}"
  end

  test "display_logo_url prefers brandfetch over stored logo_url" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    sec = Security.new(
      ticker: "AAPL",
      exchange_operating_mic: "XNAS",
      logo_url: "https://example.com/aapl.png",
      website_url: "https://www.apple.com"
    )

    url = sec.display_logo_url
    assert_includes url, "cdn.brandfetch.io/apple.com"
  end

  test "display_logo_url falls back to logo_url when brandfetch is disabled" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    sec = Security.new(
      ticker: "AAPL",
      exchange_operating_mic: "XNAS",
      logo_url: "https://example.com/aapl.png"
    )

    assert_equal "https://example.com/aapl.png", sec.display_logo_url
  end

  test "display_logo_url with no website prefers stored logo over brandfetch lettermark" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    sec = Security.new(
      ticker: "ACME",
      exchange_operating_mic: "XNAS",
      logo_url: "https://example.com/acme.png"
    )

    assert_equal "https://example.com/acme.png", sec.display_logo_url
  end
end
