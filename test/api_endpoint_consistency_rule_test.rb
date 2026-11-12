# frozen_string_literal: true

# Verifies the shared API checklist (issue #944). Ballast deleted Sure's
# .cursor/ rule adapter and replaced Sure's AGENTS.md, so only the guide is checked.
# If Rails fails to load (e.g. Sidekiq::Throttled), run the standalone script instead:
#   ruby test/support/verify_api_endpoint_consistency.rb

require "test_helper"

class ApiEndpointConsistencyRuleTest < ActiveSupport::TestCase
  GUIDE_PATH = "docs/llm-guides/api-endpoint-consistency.md"

  def root
    @root ||= Rails.root
  end

  test "shared guide includes Minitest behavioral coverage section" do
    content = File.read(root.join(GUIDE_PATH), encoding: "UTF-8")
    assert_includes content, "Minitest behavioral coverage"
    assert_includes content, "test/controllers/api/v1/{resource}_controller_test.rb"
    assert_includes content, "api_headers"
    assert_includes content, "X-Api-Key"
  end

  test "shared guide includes rswag docs-only section" do
    content = File.read(root.join(GUIDE_PATH), encoding: "UTF-8")
    assert_includes content, "rswag is docs-only"
    assert_includes content, "expect"
    assert_includes content, "assert_"
    assert_includes content, "run_test!"
    assert_includes content, "rswag:specs:swaggerize"
  end

  test "shared guide includes same API key auth section" do
    content = File.read(root.join(GUIDE_PATH), encoding: "UTF-8")
    assert_includes content, "Same API key auth"
    assert_includes content, "ApiKey.generate_secure_key"
    assert_includes content, "plain_key"
  end
end
