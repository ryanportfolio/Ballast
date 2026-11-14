class Provider::Anthropic < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Anthropic::Error
  Error = Class.new(Provider::Error)

  # Supported Anthropic model prefixes
  DEFAULT_ANTHROPIC_MODEL_PREFIXES = %w[claude].freeze
  DEFAULT_MODEL = "claude-sonnet-4-6"

  # All Claude 3.5+ and 4.x models accept native document content blocks.
  VISION_CAPABLE_MODEL_PREFIXES = %w[claude].freeze

  # Claude 3.x, 4.x and Haiku 5.5 accept a forced `tool_choice`. Anything else
  # gets `auto` (Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1 reject a forced
  # one), so a model released after this line still works. Matches anywhere in
  # the ID to cover Bedrock (`anthropic.claude-sonnet-4-5-…-v1:0`) and Vertex
  # (`claude-sonnet-4-5@…`) IDs.
  FORCED_TOOL_CHOICE_MODELS = /claude-(?:3|(?:opus|sonnet|haiku)-4|haiku-5[-.]5)(?!\d)/

  def self.forced_tool_choice_supported?(model)
    model.to_s.match?(FORCED_TOOL_CHOICE_MODELS)
  end

  # The tool_choice for a helper that returns its result through a single tool.
  # Models that can't be forced get `auto`, paired with structured_output_system.
  def self.structured_output_tool_choice(model, tool_name)
    if forced_tool_choice_supported?(model)
      { type: "tool", name: tool_name, disable_parallel_tool_use: true }
    else
      { type: "auto", disable_parallel_tool_use: true }
    end
  end

  # The system prompt for a helper that returns its result through a single tool.
  # With `auto`, a family's prompt override may not mention the tool, so a fixed
  # instruction to call it is appended.
  def self.structured_output_system(instructions, model, tool_name)
    return instructions if forced_tool_choice_supported?(model)

    "#{instructions}\n\nReturn the result by calling the #{tool_name} tool. Do not answer with text."
  end

  def self.effective_model
    # Use ENV[].presence rather than ENV.fetch(KEY, default) so the Setting
    # lookup is only performed when the ENV var is actually absent — otherwise
    # the default arg is evaluated eagerly on every call.
    configured_model = ENV["ANTHROPIC_MODEL"].presence || Setting.anthropic_model
    configured_model.presence || DEFAULT_MODEL
  end

  def self.configured?
    ENV["ANTHROPIC_ACCESS_TOKEN"].present? ||
      ENV["ANTHROPIC_API_KEY"].present? ||
      Setting.anthropic_access_token.present?
  end

  def initialize(access_token, base_url: nil, model: nil)
    client_options = { api_key: access_token }
    client_options[:base_url] = base_url if base_url.present?
    client_options[:timeout] = ENV.fetch("ANTHROPIC_REQUEST_TIMEOUT", 600).to_i

    @client = ::Anthropic::Client.new(**client_options)
    @base_url = base_url

    if custom_endpoint? && model.blank?
      raise Error, "Model is required when using a custom Anthropic-compatible endpoint"
    end

    @default_model = model.presence || DEFAULT_MODEL
  end

  def supports_model?(model)
    # Custom endpoints (Bedrock, Vertex, or other Anthropic-compatible proxies)
    # use their own model-ID conventions — e.g. Bedrock IDs look like
    # `anthropic.claude-sonnet-4-5-20250929-v1:0`. Mirror the OpenAI provider
    # and bypass the prefix gate when the caller has wired a custom base_url.
    return true if custom_endpoint?

    DEFAULT_ANTHROPIC_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def provider_name
    custom_endpoint? ? "Custom Anthropic-compatible (#{@base_url})" : "Anthropic"
  end

  def supported_models_description
    if custom_endpoint?
      "configured model: #{@default_model}"
    else
      "models starting with: #{DEFAULT_ANTHROPIC_MODEL_PREFIXES.join(', ')}"
    end
  end

  def custom_endpoint?
    @base_url.present?
  end

  def auto_categorize(transactions: [], user_categories: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      if user_categories.blank?
        family_id = family&.id || "unknown"
        Rails.logger.error("Cannot auto-categorize transactions for family #{family_id}: no categories available")
        raise Error, "No categories available for auto-categorization"
      end

      effective_model = model.presence || @default_model

      AutoCategorizer.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_categories: user_categories,
        family: family
      ).auto_categorize
    end
  end

  def suggest_bill_setup(charges: [], categories: [], current_config: nil, model: "", family: nil)
    with_provider_response do
      effective_model = model.presence || @default_model

      BillSetupSuggester.new(
        client,
        model: effective_model,
        charges: charges,
        categories: categories,
        current_config: current_config
      ).suggest
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      effective_model = model.presence || @default_model

      AutoMerchantDetector.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_merchants: user_merchants,
        family: family
      ).auto_detect_merchants
    end
  end

  def enhance_provider_merchants(merchants: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      effective_model = model.presence || @default_model

      ProviderMerchantEnhancer.new(
        client,
        model: effective_model,
        merchants: merchants
      ).enhance_merchants
    end
  end

  def supports_pdf_processing?(model: @default_model)
    return true if custom_endpoint?

    VISION_CAPABLE_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def process_pdf(pdf_content:, model: "", family: nil)
    with_provider_response do
      effective_model = model.presence || @default_model
      raise Error, "Model does not support PDF processing: #{effective_model}" unless supports_pdf_processing?(model: effective_model)

      PdfProcessor.new(
        client,
        model: effective_model,
        pdf_content: pdf_content
      ).process
    end
  end

  def extract_bank_statement(pdf_content:, model: "", family: nil)
    with_provider_response do
      effective_model = model.presence || @default_model

      BankStatementExtractor.new(
        client: client,
        pdf_content: pdf_content,
        model: effective_model
      ).extract
    end
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil
  )
    with_provider_response do
      chat_config = ChatConfig.new(
        prompt: prompt,
        instructions: instructions,
        functions: functions,
        function_results: function_results,
        tool_choice: tool_choice,
        conversation_history: conversation_history,
        default_max_tokens: default_max_tokens
      )

      request_params = chat_config.build_request(model: model)

      if streamer.present?
        stream_chat_response(streamer: streamer, request_params: request_params)
      else
        sync_chat_response(request_params: request_params)
      end
    end
  end

  private
    attr_reader :client

    def default_max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def sync_chat_response(request_params:)
      raw = client.messages.create(**request_params)
      ChatParser.new(raw).parsed
    end

    def stream_chat_response(streamer:, request_params:)
      final_message = nil
      stream = client.messages.stream(**request_params)

      stream.each do |event|
        case event
        when ::Anthropic::Streaming::TextEvent
          streamer.call(
            Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: event.text, usage: nil)
          )
        when ::Anthropic::Streaming::MessageStopEvent
          final_message = event.message
        end
      end

      final_message ||= safe_accumulated_message(stream)
      parsed = ChatParser.new(final_message).parsed
      usage = build_usage_hash(final_message.usage)

      streamer.call(
        Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed, usage: usage)
      )

      parsed
    end

    def safe_accumulated_message(stream)
      stream.accumulated_message
    rescue StandardError
      nil
    end

    def build_usage_hash(raw_usage)
      return {} unless raw_usage

      input = raw_usage.input_tokens.to_i
      output = raw_usage.output_tokens.to_i
      hash = {
        "input_tokens" => input,
        "output_tokens" => output,
        "total_tokens" => input + output
      }

      if raw_usage.respond_to?(:cache_creation_input_tokens) && raw_usage.cache_creation_input_tokens
        hash["cache_creation_input_tokens"] = raw_usage.cache_creation_input_tokens
      end
      if raw_usage.respond_to?(:cache_read_input_tokens) && raw_usage.cache_read_input_tokens
        hash["cache_read_input_tokens"] = raw_usage.cache_read_input_tokens
      end

      hash
    end
end
