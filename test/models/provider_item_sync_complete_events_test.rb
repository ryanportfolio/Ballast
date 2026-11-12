require "test_helper"
require "turbo/broadcastable/test_helper"

# #3630. A provider card lists every account on its connection, and a
# broadcast on the family stream is rendered with no viewer and reaches
# every member. No provider's sync completion may send it; the family sync
# toast makes each browser re-fetch its own, filtered page instead.
class ProviderItemSyncCompleteEventsTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  PROVIDERS = %w[
    fio_item
    lunchflow_item mercury_item monobank_item plaid_item redbark_item
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

  # Providers without fixtures, built with only what their validations need.
  {
    "akahu_item" => { app_token: "app", user_token: "user" },
    "sophtron_item" => { user_id: "user", access_key: "key" },
    "up_item" => { access_token: "token" }
  }.each do |provider, attributes|
    test "a #{provider} sync completion sends the toast, not the card" do
      item = families(:dylan_family).public_send(provider.pluralize).create!(name: "Connection", **attributes)
      Current.reset

      streams = capture_turbo_stream_broadcasts(item.family) do
        "#{provider.camelize}::SyncCompleteEvent".constantize.new(item).broadcast
      end
      targets = streams.map { |stream| stream["target"] }

      assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
      assert_includes targets, "sync-toast"
    end
  end
end
