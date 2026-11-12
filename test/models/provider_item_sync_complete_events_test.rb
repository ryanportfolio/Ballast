require "test_helper"
require "turbo/broadcastable/test_helper"

# #3630. A provider card lists every account on its connection, and a
# broadcast on the family stream is rendered with no viewer and reaches
# every member. No provider's sync completion may send it; the family sync
# toast makes each browser re-fetch its own, filtered page instead.
class ProviderItemSyncCompleteEventsTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  PROVIDERS = %w[
    mercury_item plaid_item
    wise_item
  ].freeze

  PROVIDERS.each do |provider|
    test "a #{provider} sync completion sends the toast, not the card" do
      item = provider.camelize.constantize.first!
      Current.reset

      streams = capture_turbo_stream_broadcasts(item.family) do
        "#{provider.camelize}::SyncCompleteEvent".constantize.new(item).broadcast
      end
      targets = streams.map { |stream| stream["target"] }

      assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
      assert_includes targets, "sync-toast"
    end
  end

  # simplefin_items.yml is empty; SimpleFIN tests build their own item.
  test "a simplefin_item sync completion sends the toast, not the card" do
    item = families(:dylan_family).simplefin_items.create!(name: "SimpleFIN Connection", access_url: "https://example.com/access")
    Current.reset

    streams = capture_turbo_stream_broadcasts(item.family) do
      SimplefinItem::SyncCompleteEvent.new(item).broadcast
    end
    targets = streams.map { |stream| stream["target"] }

    assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
    assert_includes targets, "sync-toast"
  end
end
