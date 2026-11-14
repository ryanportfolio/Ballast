# Fills in a transaction's missing merchant from its near-duplicates
# (Family::SimilarMatcher): when at least similar_min_neighbours of them have a
# confirmed merchant, and all the same one. Confirmed means, by default
# (similar_skip_self): not its own recent copy, unless the user locked it (a
# lock it set itself, lock_similar_merchants, doesn't count), so a wrong copy
# isn't spread. AI merchants count: the detector locks what it sets. The pool
# is the newest transactions with a merchant, capped.
# Transfers neither give nor get one: they have no merchant, and a
# description typed in the banking app makes them look alike.
class Family::SimilarMerchantFiller
  # On one family's history a threshold of 0.8–0.95 made little difference;
  # 2 neighbours instead of 1 halved the mistakes, most of them one shop under
  # two merchants. The pool is held in memory, so it's capped; the newest
  # transactions are the most representative of current spending.
  DEFAULTS = {
    lock_similar_merchants: false,
    similar_threshold: 0.9,
    similar_min_neighbours: 2,
    similar_common_share: 0.2,
    similar_skip_self: true,
    similar_self_grace_days: 90,
    max_pool_transactions: 5_000
  }.freeze

  Settings = Struct.new(*DEFAULTS.keys, keyword_init: true)

  # settings: overrides of DEFAULTS; an unknown key raises.
  def initialize(family, settings: {})
    @family = family
    @settings = Settings.new(**DEFAULTS.merge(settings))
  end

  # Returns how many of transaction_ids got a merchant.
  def fill(transaction_ids)
    return 0 if pool.size < settings.similar_min_neighbours

    matcher = Family::SimilarMatcher.new(pool, threshold: settings.similar_threshold, min_neighbours: settings.similar_min_neighbours,
                                               common_share: settings.similar_common_share)
    eligible(family.transactions.where(id: transaction_ids, merchant_id: nil).enrichable(:merchant_id))
      .includes(:entry).find_each.count do |transaction|
        merchant_id = matcher.agreed(transaction, :merchant_id)
        next false unless merchant_id

        metadata = settings.lock_similar_merchants ? { locked_by_similar: true } : {}
        filled = transaction.enrich_attribute(:merchant_id, merchant_id, source: "similar", metadata: metadata)
        transaction.lock_attr!(:merchant_id) if filled && settings.lock_similar_merchants
        filled
      end
  end

  # Transactions whose merchant can be copied, any date.
  def confirmed
    scope = eligible(family.transactions.where.not(merchant_id: nil).joins(:entry))
    scope = scope.where.not(own_copy_sql(settings.similar_self_grace_days.days.ago)) if settings.similar_skip_self
    scope
  end

  # The newest of them.
  def pool
    @pool ||= confirmed.preload(:entry)
                       .order("transactions.created_at DESC, transactions.id DESC")
                       .limit(settings.max_pool_transactions)
                       .to_a
  end

  private
    attr_reader :family, :settings

    # The merchant is still the matcher's recent copy, unlocked or locked by
    # the matcher itself.
    def own_copy_sql(cutoff)
      "#{Transaction.enriched_from_sql("merchant_id", "similar", since: cutoff)} AND (NOT (transactions.locked_attributes ? 'merchant_id') " \
        "OR #{Transaction.enriched_from_sql("merchant_id", "similar", metadata: { locked_by_similar: true })})"
    end

    def eligible(scope)
      scope.where.not(kind: Transaction::TRANSFER_KINDS)
    end
end
