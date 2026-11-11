# frozen_string_literal: true

module Admin
  class SystemHealthController < Admin::BaseController
    # Bypass the per-request memo / cross-request cache that the layout
    # banner uses. An operator landing on this page (often right after
    # restarting the worker) wants to confirm the current state, not a
    # snapshot up to `SidekiqHealth::CACHE_TTL` old. Also makes the page
    # work in managed mode, where `current_sidekiq_health` is nil.
    def show
      tabs = %w[background_jobs ai configuration]
      @active_tab = params[:tab].presence_in(tabs) || "background_jobs"
      @configuration_health = ConfigurationHealth.new
      SidekiqHealth.expire_cache!
      @health = SidekiqHealth.new
    end

    # Each live probe can take up to AiHealth::Probe.timeout, so the page
    # loads this into its AI tab through a lazy frame instead of waiting on
    # the probes before it renders.
    def ai_status
      @ai_health = AiHealth.new(force_probes: params[:refresh_ai_health] == "1")
      @worker_ai_health_results = WorkerAiHealth.recent
      render layout: false
    end

    # Queues an asynchronous worker-side verification (see
    # WorkerAiHealthCheckJob) and returns immediately -- the result appears
    # in the AI status tab once whichever worker process dequeues it
    # finishes, typically within a few seconds.
    def verify_worker_ai
      WorkerAiHealth.request_check!
      redirect_to admin_system_health_path(tab: "ai", locale: locale_from_param), notice: t(".queued")
    end
  end
end
