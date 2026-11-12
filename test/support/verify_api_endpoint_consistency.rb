# frozen_string_literal: true

# Standalone verification of the API endpoint consistency implementation (issue #944).
# Run without loading Rails: ruby test/support/verify_api_endpoint_consistency.rb
# Or with bundle: bundle exec ruby test/support/verify_api_endpoint_consistency.rb
# Ballast deleted Sure's .cursor/ rule adapter and replaced Sure's AGENTS.md,
# so only the shared guide is checked.
#
# Option: pass --compliance to also scan the current API codebase and report violations
# (rswag specs using Bearer tokens instead of API key, missing Minitest for API controllers,
# rswag specs with expect/assert).

def project_root
  dir = File.dirname(File.expand_path(__FILE__))
  loop do
    return dir if File.exist?(File.join(dir, "AGENTS.md")) && File.directory?(File.join(dir, "docs", "llm-guides"))
    parent = File.dirname(dir)
    raise "Could not find project root (AGENTS.md + docs/llm-guides)" if parent == dir
    dir = parent
  end
end

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

def assert_includes(content, substring, message)
  assert content.include?(substring), "#{message} (missing: #{substring.inspect})"
end

root = project_root
guide_path = File.join(root, "docs", "llm-guides", "api-endpoint-consistency.md")

assert File.exist?(guide_path), "Shared checklist should exist at #{guide_path}"
guide_content = File.read(guide_path, encoding: "UTF-8")

assert_includes guide_content, "Minitest behavioral coverage", "Shared checklist must include Minitest section"
assert_includes guide_content, "test/controllers/api/v1/{resource}_controller_test.rb", "Shared checklist must specify Minitest location"
assert_includes guide_content, "api_headers", "Shared checklist must mention api_headers"
assert_includes guide_content, "X-Api-Key", "Shared checklist must mention X-Api-Key"
assert_includes guide_content, "rswag is docs-only", "Shared checklist must include rswag docs-only section"
assert_includes guide_content, "run_test!", "Shared checklist must mention run_test!"
assert_includes guide_content, "rswag:specs:swaggerize", "Shared checklist must mention swaggerize task"
assert_includes guide_content, "Same API key auth", "Shared checklist must include API key auth section"
assert_includes guide_content, "ApiKey.generate_secure_key", "Shared checklist must show API key pattern"
assert_includes guide_content, "plain_key", "Shared checklist must mention plain_key"

puts "OK: API endpoint consistency shared checklist verified."

if ARGV.include?("--compliance")
  puts "\n--- Compliance check (current APIs) ---"
  spec_dir = File.join(root, "spec", "requests", "api", "v1")
  test_dir = File.join(root, "test", "controllers", "api", "v1")
  app_controllers_dir = File.join(root, "app", "controllers", "api", "v1")

  rswag_bearer = []
  rswag_assertions = []
  missing_minitest = []

  if File.directory?(spec_dir)
    Dir.glob(File.join(spec_dir, "*_spec.rb")).each do |path|
      basename = File.basename(path, "_spec.rb")
      content = File.read(path, encoding: "UTF-8")
      if content.include?("Bearer") || content.include?("access_token")
        rswag_bearer << "#{basename}_spec.rb"
      end
      rswag_assertions << "#{basename}_spec.rb" if content.include?("expect(") || content.include?("assert_")
    end
  end

  skip_controllers = %w[base_controller test_controller]
  if File.directory?(app_controllers_dir)
    Dir.glob(File.join(app_controllers_dir, "*_controller.rb")).each do |path|
      basename = File.basename(path, ".rb")
      next if skip_controllers.include?(basename)
      test_path = File.join(test_dir, "#{basename}_test.rb")
      missing_minitest << basename unless File.exist?(test_path)
    end
  end

  if rswag_bearer.any?
    puts "rswag using Bearer tokens (should use API key per rule): #{rswag_bearer.join(", ")}"
  else
    puts "rswag auth: all specs use API key."
  end

  if rswag_assertions.any?
    puts "rswag with expect/assert (should be docs-only): #{rswag_assertions.join(", ")}"
  else
    puts "rswag: no expect/assert found (docs-only)."
  end

  if missing_minitest.any?
    puts "API v1 controllers missing Minitest: #{missing_minitest.join(", ")}"
  else
    puts "Minitest: all API v1 controllers have a test file."
  end

  puts "---"
end
