require "test_helper"

class Category::MergerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
  end

  test "merge only reassigns and deletes categories inside the current family" do
    target = create_category(@family, "Cross Family Merge Target")
    source = create_category(@family, "Cross Family Merge Source")
    source_child = create_category(@family, "Cross Family Merge Child", parent: source)
    transaction = create_transaction_for(@family, source)

    other_target = create_category(@other_family, target.name)
    other_source = create_category(@other_family, source.name)
    other_child = create_category(@other_family, source_child.name, parent: other_source)
    other_transaction = create_transaction_for(@other_family, other_source)

    other_family_snapshot = -> {
      {
        target_exists: Category.exists?(other_target.id),
        source_exists: Category.exists?(other_source.id),
        child_parent_id: other_child.reload.parent_id,
        transaction_category_id: other_transaction.reload.category_id
      }
    }

    assert_no_changes other_family_snapshot do
      merger = Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source ]
      )

      assert merger.merge!
    end

    assert_equal target.id, transaction.reload.category_id
    assert_equal target.id, source_child.reload.parent_id
    assert_not Category.exists?(source.id)
  end

  test "merging categories invalidates entries_cache_version" do
    target = create_category(@family, "Cache Merge Target")
    source = create_category(@family, "Cache Merge Source")
    transaction = create_transaction_for(@family, source)

    before = @family.reload.entries_cache_version

    travel 1.second do
      merger = Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source ]
      )

      assert merger.merge!
    end

    assert_equal target.id, transaction.reload.category_id
    assert_not_equal before, @family.reload.entries_cache_version
  end

  private
    def create_category(family, name, parent: nil)
      family.categories.create!(
        name: name,
        color: "#000000",
        lucide_icon: "shapes",
        parent: parent
      )
    end

    def create_transaction_for(family, category)
      transaction = Transaction.create!(category: category)
      Entry.create!(
        account: account_for(family),
        entryable: transaction,
        name: "#{category.name} transaction",
        date: Date.current,
        amount: 10,
        currency: family.currency || "USD"
      )

      transaction
    end

    def account_for(family)
      family.accounts.first || family.accounts.create!(
        accountable: Depository.create!(subtype: "checking"),
        name: "#{family.name} Checking",
        balance: 0,
        currency: family.currency || "USD"
      )
    end
end
