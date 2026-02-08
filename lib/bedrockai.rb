# frozen_string_literal: true

require 'aws-sdk-bedrockruntime'
require 'logger'

require_relative 'bedrockai/version'
require_relative 'bedrockai/errors'
require_relative 'bedrockai/stream_chunk'
require_relative 'bedrockai/response'
require_relative 'bedrockai/tool'
require_relative 'bedrockai/streaming'

class BedrockAi
  DEFAULT_MAX_TOKENS  = 4096
  DEFAULT_TEMPERATURE = 0.5

  def initialize(model:, region: nil, credentials: nil, logger: nil)
    raise ConfigurationError, 'model must be a non-empty string' if !model.is_a?(String) || model.strip.empty?

    @model = model
    @max_tokens  = DEFAULT_MAX_TOKENS
    @temperature = DEFAULT_TEMPERATURE
    @system_prompt = nil
    @tools       = {}
    @responses   = []
    @thinking    = nil
    @output_schema = nil
    @logger = logger || Logger.new($stdout)

    client_opts = {}
    client_opts[:region]      = region      if region
    client_opts[:credentials] = credentials if credentials
    @client = Aws::BedrockRuntime::Client.new(**client_opts)
  end

  def set_temperature(value)
    unless value.is_a?(Numeric) && value >= 0.0 && value <= 1.0
      raise ConfigurationError, 'Temperature must be a number between 0.0 and 1.0'
    end

    if @thinking && (value.to_f - 1.0).abs > Float::EPSILON
      raise ConfigurationError,
            'Temperature must be 1.0 when thinking is enabled'
    end

    @temperature = value.to_f
    self
  end

  def set_max_tokens(value)
    raise ConfigurationError, 'max_tokens must be a positive integer' unless value.is_a?(Integer) && value.positive?

    @max_tokens = value
    self
  end

  def set_system_prompt(prompt)
    raise ConfigurationError, 'System prompt must be a non-empty string' if !prompt.is_a?(String) || prompt.strip.empty?

    @system_prompt = prompt
    self
  end

  # Enables extended thinking with the given token budget (Anthropic models only).
  # Temperature must be 1.0 when thinking is enabled.
  def enable_thinking(budget_tokens: 10_000)
    unless budget_tokens.is_a?(Integer) && budget_tokens.positive?
      raise ConfigurationError, 'budget_tokens must be a positive integer'
    end

    unless (@temperature - 1.0).abs <= Float::EPSILON
      raise ConfigurationError, 'Temperature must be 1.0 when thinking is enabled'
    end

    @thinking = { budget_tokens: budget_tokens }
    self
  end

  def disable_thinking
    @thinking = nil
    self
  end

  # Constrains the model's output to match a JSON schema (RubyLLM::Schema subclass).
  def set_output_schema(schema)
    if schema.nil?
      @output_schema = nil
      return self
    end

    unless schema.respond_to?(:to_json_schema)
      raise ConfigurationError, 'Schema must respond to `to_json_schema` (inherit from RubyLLM::Schema)'
    end

    @output_schema = schema
    self
  end

  # Registers a tool (BedrockAi::Tool subclass) for the model to call.
  def add_tool(tool)
    raise ConfigurationError, "Expected a BedrockAi::Tool, got #{tool.class}" unless tool.is_a?(Tool)

    raise ConfigurationError, "A tool named '#{tool.name}' is already registered" if @tools.key?(tool.name)

    @tools[tool.name] = tool
    self
  end

  # Restores a prior exchange into the conversation history.
  def add_response(response)
    raise ConfigurationError, "Expected a Response, got #{response.class}" unless response.is_a?(Response)

    @responses << response
    self
  end

  # Sends a prompt, streams the response, and appends the exchange to history.
  def query(prompt, &)
    if !prompt.is_a?(String) || prompt.strip.empty?
      raise ConfigurationError,
            'Prompt must be a non-empty string'
    end

    streaming = build_streaming
    streaming.add_messages(messages)
    response = streaming.stream(prompt, &)
    add_response(response)
    response
  end

  private

  # Flattens all prior response messages into a single conversation array.
  def messages
    @responses.flat_map(&:messages)
  end

  def build_streaming
    Streaming.new(
      client: @client,
      model: @model,
      max_tokens: @max_tokens,
      temperature: @temperature,
      system_prompt: @system_prompt,
      tools: @tools,
      thinking: @thinking,
      output_schema: @output_schema,
      logger: @logger
    )
  end
end
