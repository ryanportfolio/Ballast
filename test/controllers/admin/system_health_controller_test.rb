require "test_helper"

class Admin::SystemHealthControllerTest < ActionDispatch::IntegrationTest
  AI_ENVIRONMENT = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL OPENAI_REQUEST_TIMEOUT
    OPENAI_SUPPORTS_PDF_PROCESSING OPENAI_SUPPORTS_RESPONSES_ENDPOINT
    ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_REQUEST_TIMEOUT
    AI_HEALTH_PROBE_TIMEOUT AI_HEALTH_PROBE_CACHE_TTL
  ].index_with(nil).freeze

  setup do
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    Setting.stubs(:anthropic_access_token).returns(nil)
    Setting.stubs(:anthropic_base_url).returns(nil)
    Setting.stubs(:anthropic_model).returns(nil)
    AiHealth::Probe.any_instance.stubs(:llm).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pdf_text_extraction).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(probe_result(:passing))
  end

  test "super admin can view the system health page" do
    sign_in users(:sure_support_staff)
    SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
    SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
    SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
    SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
    SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
    SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 0, 0.0 ] ])

    get admin_system_health_url

    assert_response :success
    assert_match(/Sidekiq status/, response.body)
    assert_match(/Healthy/, response.body)
    assert_select "button[role='tab']", text: "AI"
    # Nothing in the queue table takes focus, so on a narrow screen the scroll
    # area has to be a named tab stop of its own for a keyboard to scroll it.
    assert_select "[role='region'][aria-label='Queues']"
  end

  test "renders degraded state with reason when Sidekiq is unhealthy" do
    sign_in users(:sure_support_staff)
    SidekiqHealth.any_instance.stubs(:healthy?).returns(false)
    SidekiqHealth.any_instance.stubs(:reason).returns(:no_worker_processes)
    SidekiqHealth.any_instance.stubs(:processes_count).returns(0)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(nil)
    SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
    SidekiqHealth.any_instance.stubs(:enqueued_count).returns(7)
    SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
    SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:processed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])

    get admin_system_health_url

    assert_response :success
    assert_match(/Degraded/, response.body)
    assert_match(/No Sidekiq worker process is connected/, response.body)
  end

  test "super admin sees background job statistics" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    travel_to Time.current do
      SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(2.minutes.ago)
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 1234, 1.5 ] ])
      get admin_system_health_url
    end

    assert_response :success
    assert_select "h1", text: "System health"
    assert_select "button[role='tab'][aria-selected='true']", text: "Jobs"
    assert_select "button[role='tab']", text: "AI"
    assert_select "h2", text: "Sidekiq status"
    assert_select "h2", text: "Job counters"
    assert_select "h2", text: "Queues"
    assert_select "dd", text: "Healthy"
    assert_select "dd", text: "2 minutes ago"
    {
      "Status" => "Healthy", "Worker processes" => "1",
      "Last heartbeat" => "2 minutes ago", "Oldest job age" => "0.0s",
      "Enqueued" => "0", "Retries" => "0",
      "Failed" => "0", "Processed total" => "42"
    }.each do |label, value|
      assert_select "dl > div" do |items|
        item = items.find { |element| element.at_css("dt")&.text == label }
        assert item, "Missing statistic: #{label}"
        assert_equal value, item.at_css("dd").text.strip
      end
    end
    assert_select "th", text: "Size"
    assert_select "th", text: "Latency"
    assert_select "td", text: "default"
    assert_select "td", text: "1,234"
    assert_select "td", text: "1.5s"
  end

  test "background job statistics show degraded and empty states" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    SidekiqHealth.any_instance.stubs(:healthy?).returns(false)
    SidekiqHealth.any_instance.stubs(:reason).returns(:no_worker_processes)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(nil)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])

    get admin_system_health_url

    assert_response :success
    assert_select "dd", text: "Degraded"
    assert_select "dd", text: "Never"
    assert_match(/Background jobs aren(&#39;|')t running/, response.body)
    assert_select "p", text: "No queues are registered. The worker may not be running."
  end

  test "non super admin is redirected away" do
    sign_in users(:family_admin)

    get admin_system_health_url

    assert_redirected_to root_path
  end

  test "unauthenticated user is redirected to sign in" do
    get admin_system_health_url

    assert_redirected_to new_session_path
  end

  test "only super admins can run the AI checks" do
    AiHealth::Probe.any_instance.expects(:llm).never

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
      assert_redirected_to new_session_path

      sign_in users(:family_admin)
      get ai_status_admin_system_health_url
      assert_redirected_to root_path
    end
  end

  test "AI status reports the default OpenAI LLM" do
    sign_in users(:sure_support_staff)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "turbo-frame#ai_status"
    assert_match(/LLM and PDF processing/, response.body)
    assert_select "[data-testid='selected-llm-provider']", text: "OpenAI"
    assert_select "[data-testid='effective-llm-provider']", text: "OpenAI"
    assert_match(/gpt-4\.1/, response.body)
    assert_match(%r{https://api\.openai\.com/v1}, response.body)
    assert_match(/Live check passed/, response.body)
    assert_match(/PDF text-extraction path/, response.body)
    assert_match(/PDF vision\/native path/, response.body)
    assert_equal 2, response.body.scan(/Synthetic PDF check passed/).size
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "the page leaves the AI probes to a lazy frame on either tab" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.expects(:llm).never
    AiHealth::Probe.any_instance.expects(:function_calling).never
    AiHealth::Probe.any_instance.expects(:pdf_text_extraction).never
    AiHealth::Probe.any_instance.expects(:pdf_vision_processing).never

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      { "background_jobs" => "Jobs", "ai" => "AI", "configuration" => "Config" }.each do |tab, label|
        get admin_system_health_url(tab: tab)

        assert_response :success
        assert_select "button[role='tab'][aria-selected='true']", text: label
        assert_select "turbo-frame#ai_status[loading='lazy'][src='#{ai_status_admin_system_health_path}']",
          text: "Running live checks…"
      end
    end
  end

  test "the lazy frame keeps the page's refresh and English locale override" do
    sign_in users(:sure_support_staff)

    get admin_system_health_url(tab: "ai", refresh_ai_health: "1", locale: "en")

    assert_select "turbo-frame#ai_status[src='#{ai_status_admin_system_health_path(refresh_ai_health: "1", locale: "en")}']"
  end

  test "the lazy frame drops a refresh or locale it can't use" do
    sign_in users(:sure_support_staff)

    [
      { refresh_ai_health: "0", locale: "xx" },
      { refresh_ai_health: "0", locale: "de" },
      { refresh_ai_health: { "x" => "1" }, locale: { "x" => "de" } }
    ].each do |query|
      get admin_system_health_url(tab: "ai", **query)

      assert_response :success
      assert_select "turbo-frame#ai_status[src='#{ai_status_admin_system_health_path}']"
    end
  end

  # The redirect's morph reloads the frame from its old src, so an override
  # dropped on the way would leave the page and the frame out of step.
  test "a locale override survives the worker check round trip" do
    sign_in users(:sure_support_staff)

    with_ai_environment do
      get ai_status_admin_system_health_url(locale: "en")
    end
    assert_select "form[action=?]", verify_worker_ai_admin_system_health_path(locale: "en")

    post verify_worker_ai_admin_system_health_url(locale: "en")
    assert_redirected_to admin_system_health_path(tab: "ai", locale: "en")
  end

  test "AI status names a custom OpenAI-compatible endpoint and redacts its credentials" do
    sign_in users(:sure_support_staff)

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "local-token",
      "OPENAI_URI_BASE" => credentialed_url(
        scheme: "http",
        host: "ollama",
        port: 11_434,
        path: "/v1",
        user: "operator",
        password: "uri-secret",
        query: "api_key=query-secret"
      ),
      "OPENAI_MODEL" => "qwen3:8b"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "[data-testid='selected-llm-provider']", text: "OpenAI-compatible"
    assert_select "[data-testid='effective-llm-provider']", text: "Ollama"
    assert_match(/OpenAI-compatible API credentials/, response.body)
    assert_match(%r{http://ollama:11434/v1}, response.body)
    assert_no_match(/local-token|uri-secret|query-secret/, response.body)
  end

  test "AI status names the missing function-calling support behind an unhelpful chat error" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(
      probe_result(:failing, failure_code: :tools_refused, http_status: 404)
    )

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "router-secret",
      "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1",
      "OPENAI_MODEL" => "tngtech/deepseek-r1t2-chimera:free"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "[data-testid='function-calling-status']", text: /Not supported by the effective provider/
    assert_match(/The model does not support function calling/, response.body)
    assert_match(/Function-calling failure reason/, response.body)
    assert_no_match(/router-secret/, response.body)
  end

  test "AI status names an unavailable configured LLM model" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:llm).returns(
      probe_result(:failing, failure_code: :model_not_available)
    )

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "gemini-secret",
      "OPENAI_URI_BASE" => "https://generativelanguage.googleapis.com/v1beta/openai",
      "OPENAI_MODEL" => "retired-gemini-model"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/The configured AI model is not available/, response.body)
    assert_match(/gemini-3\.8-flash/, response.body)
    assert_no_match(/gemini-secret/, response.body)
  end

  test "AI status separates a model that ignores tools from one that cannot use them" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(
      probe_result(:failing, failure_code: :no_tool_call)
    )

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "[data-testid='function-calling-status']", text: /Tools accepted, but the model called none/
    assert_match(/answered without calling the tool it was asked to call/, response.body)
    assert_no_match(/The model does not support function calling/, response.body)
  end

  test "AI status reports text and vision PDF probes separately" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(
      probe_result(:failing, failure_code: :invalid_response)
    )

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/PDF text-extraction path/, response.body)
    assert_match(/PDF vision\/native path/, response.body)
    assert_match(/The synthetic PDF vision\/native check failed/, response.body)
    assert_match(/Synthetic PDF check passed/, response.body)
    assert_match(/Synthetic PDF check failed/, response.body)
    assert_match(/Vision\/native failure reason/, response.body)
    assert_match(/unexpected response/, response.body)
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "AI status surfaces LLM and probe request timeouts as distinct values" do
    sign_in users(:sure_support_staff)

    # OPENAI_REQUEST_TIMEOUT bounds real LLM calls the app makes (chat, PDF
    # import). AI_HEALTH_PROBE_TIMEOUT only bounds the admin "live checks".
    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "local-token",
      "OPENAI_REQUEST_TIMEOUT" => "300",
      "AI_HEALTH_PROBE_TIMEOUT" => "5"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    llm_label = response.body.index("LLM request timeout")
    probe_label = response.body.index("Health-check probe timeout")
    assert llm_label, "expected an 'LLM request timeout' label on the AI status page"
    assert probe_label, "expected a 'Health-check probe timeout' label on the AI status page"
    assert_operator llm_label, :<, probe_label, "LLM timeout row should appear before the probe timeout row"
    assert response.body[llm_label, 400].include?("300s"), "LLM timeout value (300s) missing near its label"
    assert response.body[probe_label, 400].include?("5s"), "probe timeout value (5s) missing near its label"
    assert_no_match(/local-token/, response.body)
  end

  test "AI status does not probe PDF processing when it is explicitly disabled" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.expects(:pdf_text_extraction).never
    AiHealth::Probe.any_instance.expects(:pdf_vision_processing).never

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "sk-secret-openai",
      "OPENAI_SUPPORTS_PDF_PROCESSING" => "false"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/Disabled or not supported by the effective provider\/model/, response.body)
    assert_no_match(/The synthetic PDF .* check failed/, response.body)
  end

  test "AI status reports Anthropic without exposing its credentials" do
    sign_in users(:sure_support_staff)
    Setting.stubs(:llm_provider).returns("anthropic")

    with_ai_environment(
      "ANTHROPIC_ACCESS_TOKEN" => "anthropic-secret",
      "ANTHROPIC_MODEL" => "claude-sonnet-4-6"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/Anthropic/, response.body)
    assert_no_match(/anthropic-secret/, response.body)
  end

  test "AI status keeps its standing guidance collapsed" do
    sign_in users(:sure_support_staff)

    with_ai_environment do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "details:not([open]) summary", text: "Which settings need a restart?"
  end

  test "AI status explains when no worker has checked in yet" do
    sign_in users(:sure_support_staff)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/Worker verification/, response.body)
    assert_match(/No worker has checked in yet/, response.body)
  end

  test "AI status renders a worker result and flags it matching the web configuration" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          effective_provider: :openai,
          llm_model: "gpt-4.1",
          llm_endpoint: "https://api.openai.com/v1"
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_select "[data-testid='worker-process-identity']", text: "worker-1:123"
    assert_match(/Matches web/, response.body)
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "AI status flags a worker result whose configuration differs from the web process" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          effective_provider: :openai,
          llm_model: "a-different-model-than-web-resolves",
          llm_endpoint: "https://api.openai.com/v1"
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_match(/Differs from web/, response.body)
  end

  test "AI status shows a failing worker result with its failure reason" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          llm_status: :failing,
          failure_codes: [ :model_not_available ]
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_match(/The configured model was not returned by the provider/, response.body)
  end

  test "every AI failure reason renders in worker results" do
    codes = %i[
      model_not_available no_tool_call tools_refused invalid_response
      render_missing_binary timeout request_failed unsupported_provider
    ]

    sign_in users(:sure_support_staff)
    with_memory_cache do
      with_ai_environment do
        WorkerAiHealth.record!(worker_snapshot(llm_status: :failing, failure_codes: codes))
        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_select "dt", text: "Failure reason"
    codes.each do |code|
      text = I18n.t("admin.system_health.show.ai.failure_codes.#{code}", raise: true)
      assert_select "dd", text: /#{Regexp.escape(text)}/
    end
  end

  test "AI status shows a stale worker result as stale rather than passing" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          checked_at: (WorkerAiHealth::STALE_AFTER + 1.minute).ago
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_match(/Stale/, response.body)
  end

  test "verify_worker_ai queues an asynchronous worker check and redirects to the AI tab" do
    sign_in users(:sure_support_staff)

    assert_enqueued_with(job: WorkerAiHealthCheckJob) do
      post verify_worker_ai_admin_system_health_url
    end

    assert_redirected_to admin_system_health_path(tab: "ai")
    follow_redirect!
    assert_match(/Worker check queued/, response.body)
  end

  test "non super admin cannot queue a worker check" do
    sign_in users(:family_admin)

    assert_no_enqueued_jobs only: WorkerAiHealthCheckJob do
      post verify_worker_ai_admin_system_health_url
    end

    assert_redirected_to root_path
  end

  test "unauthenticated user cannot queue a worker check" do
    assert_no_enqueued_jobs only: WorkerAiHealthCheckJob do
      post verify_worker_ai_admin_system_health_url
    end

    assert_redirected_to new_session_path
  end

  test "super admin sees worker verification guidance and queued notice" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    with_memory_cache do
      with_ai_environment do
        get ai_status_admin_system_health_url
        assert_response :success
        assert_select "h2", text: "Worker verification"
        assert_select "button", text: "Verify worker configuration"
        assert_match(/No worker has checked in yet/, response.body)
        assert_match(/Each check verifies exactly one worker process/, response.body)
        assert_match(/Which settings need a restart\?/, response.body)
        assert_match(/no restart needed/, response.body)
        assert_match(/both the web and worker services/, response.body)

        assert_enqueued_with(job: WorkerAiHealthCheckJob) do
          post verify_worker_ai_admin_system_health_url
        end
        assert_redirected_to admin_system_health_path(tab: "ai")
        follow_redirect!
        assert_match(/Worker check queued/, response.body)
      end
    end
  end

  test "worker results distinguish passing failing stale and differing configurations" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "synthetic-token") do
        [
          [ {}, "Passing", "Matches web" ],
          [ { llm_status: :failing, llm_model: "different-model" }, "Failing", "Differs from web" ],
          [ { checked_at: (WorkerAiHealth::STALE_AFTER + 1.minute).ago }, "Stale", "Matches web" ]
        ].each do |overrides, status, configuration|
          WorkerAiHealth.record!(worker_snapshot(**overrides))
          get ai_status_admin_system_health_url
          assert_response :success
          assert_select "[data-testid='worker-ai-health-result']" do
            assert_select "[data-testid='worker-process-identity']", text: "worker:1"
            assert_select "p", text: /Checked\b.*\bago/m
            assert_select "span", text: status
            assert_select "span", text: configuration
          end
          assert_no_match(/synthetic-token/, response.body)
        end
      end
    end
  end

  test "configuration tab reports missing email and provider configuration without secrets or probes" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    ApplicationMailer.stubs(:perform_deliveries).returns(true)
    ApplicationMailer.stubs(:delivery_method).returns(:smtp)
    ApplicationMailer.stubs(:smtp_settings).returns({ address: nil, port: nil, password: "smtp-secret" })
    ApplicationMailer.stubs(:default).returns({ from: "Sure <sender@sure.local>" })
    ApplicationMailer.stubs(:default_url_options).returns({})
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data", "yahoo_finance" ])
    Setting.stubs(:twelve_data_api_key).returns(nil)
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")
    Provider::TwelveData.any_instance.expects(:usage).never
    Provider::YahooFinance.any_instance.expects(:health_status).never
    AiHealth.expects(:new).never

    ClimateControl.modify("TWELVE_DATA_API_KEY" => nil, "EXCHANGE_RATE_PROVIDER" => nil) do
      get admin_system_health_url(tab: "configuration")
    end

    assert_response :success
    assert_select "button[role='tab'][aria-selected='true']", text: "Config"
    assert_select "[data-testid='configuration-smtp']" do
      assert_select "h2", text: "Email (SMTP)"
      assert_select "li", text: "SMTP_ADDRESS"
      assert_match(/SMTP cannot be configured in the admin UI/, response.body)
    end
    assert_select "[data-testid='configuration-securities']" do
      assert_select "span", text: "Incomplete configuration"
      assert_select "dt", text: "Twelve Data"
      assert_select "dd", text: "API key missing"
      assert_select "dt", text: "Yahoo Finance"
    end
    assert_select "[data-testid='configuration-exchange_rates']" do
      assert_select "span", text: "Not configured"
    end
    assert_select "[data-testid='configuration-storage']"
    assert_select "[data-testid='configuration-smtp'] code", text: "SMTP_USERNAME"
    assert_no_match(/smtp-secret/, response.body)
  end

  test "configuration tab does not expose configured mailer or storage values" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    ApplicationMailer.stubs(:perform_deliveries).returns(true)
    ApplicationMailer.stubs(:delivery_method).returns(:smtp)
    ApplicationMailer.stubs(:smtp_settings).returns({
      address: "smtp.private.test", port: 587, user_name: "private-user", password: "private-password"
    })
    ApplicationMailer.stubs(:default).returns({ from: "Sure <private-sender@private.test>" })
    ApplicationMailer.stubs(:default_url_options).returns({ host: "private-domain.test" })
    Rails.application.config.active_storage.stubs(:service).returns(:local)
    Rails.application.config.active_storage.stubs(:service_configurations).returns({
      local: { service: "Disk", root: "/private-storage-root" }
    })

    get admin_system_health_url(tab: "configuration")

    assert_response :success
    assert_select "[data-testid='configuration-smtp'] span", text: "Configured"
    assert_select "[data-testid='configuration-storage'] span", text: "Configured"
    assert_no_match(/private-|smtp.private.test/, response.body)
  end

  test "configuration tab names each section" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    get admin_system_health_url(tab: "configuration")

    assert_response :success
    assert_select "button[role='tab'][aria-selected='true']", text: "Config"
    assert_select "[data-testid='configuration-smtp'] h2", text: "Email (SMTP)"
    assert_select "[data-testid='configuration-securities'] h2", text: "Market prices"
    assert_select "[data-testid='configuration-exchange_rates'] h2", text: "Foreign exchange rates"
    assert_select "[data-testid='configuration-storage'] h2", text: "File uploads and storage"
  end

  test "optional services are at the bottom with neutral absent statuses and collapsed guidance" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    get admin_system_health_url(tab: "configuration")

    assert_response :success
    assert_select "[data-testid='configuration-health'] > :last-child[data-testid='optional-services']" do
      assert_select "h2", text: "Optional services"
      assert_select "details:not([open])", count: 4
      %w[Sentry Skylight PostHog Logtail].each do |name|
        assert_select "summary span", text: name
      end
      assert_select "input, form, button", count: 0
    end
  end

  test "optional service rendering exposes no configured values and creates no clients" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    Sentry.stubs(:configuration).returns(OpenStruct.new(dsn: "optional-sentry-secret", enabled_in_current_env?: true))
    PostHog::Client.expects(:new).never
    Sentry.expects(:capture_exception).never
    Logtail::Logger.expects(:create_default_logger).never
    posthog = Rails.configuration.x.posthog.clone
    posthog.api_key = "optional-posthog-secret"
    posthog.host = "https://optional-private-host.test"
    Rails.configuration.x.stubs(:posthog).returns(posthog)

    ClimateControl.modify(
      "SKYLIGHT_AUTHENTICATION" => "optional-skylight-secret", "LOGTAIL_API_KEY" => "optional-logtail-secret",
      "LOGTAIL_INGESTING_HOST" => "optional-logtail-host"
    ) do
      get admin_system_health_url(tab: "configuration")
    end

    assert_response :success
    assert_select "[data-testid='optional-services']" do |section|
      assert_no_match(/optional-.*?(secret|host)/, section.first.to_html)
      assert_select "[data-testid='optional-service-skylight'] summary", text: /Configured/
    end
  end

  test "optional service copy renders with setup guidance" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    get admin_system_health_url(tab: "configuration")

    assert_response :success
    assert_select "[data-testid='optional-services'] h2", text: "Optional services"
    assert_select "[data-testid='optional-service-logtail'] p", text: /LOGTAIL_INGESTING_HOST/
  end

  test "provider settings links belong only to the two provider cards in self hosted mode" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    ClimateControl.modify("EXCHANGE_RATE_PROVIDER" => "private-invalid-provider") do
      get admin_system_health_url(tab: "configuration")
    end
    %w[securities exchange_rates].each do |key|
      assert_select "[data-testid='configuration-#{key}'] a[href=?]", settings_hosting_path, count: 1
    end
    assert_select "[data-testid='configuration-health'] a[href=?]", settings_hosting_path, count: 2
    assert_select "[data-testid='configuration-exchange_rates']" do
      assert_select "span", text: "Not configured"
      assert_select "li", text: /Automatic rate lookups fail/
    end
    assert_no_match(/private-invalid-provider/, response.body)
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    get admin_system_health_url(tab: "configuration")
    assert_select "[data-testid='configuration-health'] a[href=?]", settings_hosting_path, count: 0
  end

  test "configuration tab preserves super admin authorization" do
    ConfigurationHealth.expects(:new).never
    get admin_system_health_url(tab: "configuration")
    assert_redirected_to new_session_path

    sign_in users(:family_admin)
    get admin_system_health_url(tab: "configuration")
    assert_redirected_to root_path
  end

  private
    # Stubs Rails.cache with an in-process MemoryStore for the duration of
    # the block. Test env normally runs a NullStore (see config/environments/test.rb),
    # under which WorkerAiHealth.record!/.recent (both cache: Rails.cache by
    # default) would silently no-op -- fine for controller tests that don't
    # care about worker results, but these need the round trip to actually work.
    def with_memory_cache
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      yield
    ensure
      Rails.unstub(:cache)
    end

    def worker_snapshot(overrides = {})
      WorkerAiHealth::Snapshot.new(
        **{
          process_identity: "worker:1",
          hostname: "worker",
          pid: 1,
          checked_at: Time.current,
          effective_provider: :openai,
          llm_model: "gpt-4.1",
          llm_endpoint: "https://api.openai.com/v1",
          llm_request_timeout: 60,
          function_calling_status: :supported,
          llm_status: :passing,
          failure_codes: []
        }.merge(overrides)
      )
    end

    def credentialed_url(scheme:, host:, port:, user:, password:, path: nil, query: nil)
      URI::Generic.build(
        scheme: scheme,
        userinfo: "#{user}:#{password}",
        host: host,
        port: port,
        path: path,
        query: query
      ).to_s
    end

    def probe_result(status, failure_code: nil, http_status: nil)
      AiHealth::Probe::Result.new(
        status: status,
        checked_at: status.in?([ :passing, :failing ]) ? Time.current : nil,
        failure_code: failure_code,
        http_status: http_status
      )
    end

    def with_ai_environment(overrides = {}, &block)
      ClimateControl.modify(AI_ENVIRONMENT.merge(overrides), &block)
    end

    def stub_healthy_sidekiq
      SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
      SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
      SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
      SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
      SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
      SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
      SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
      SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 0, 0.0 ] ])
    end
end
