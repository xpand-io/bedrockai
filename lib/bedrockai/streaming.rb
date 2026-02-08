# frozen_string_literal: true

require 'json'
require 'concurrent'

class BedrockAi
  class Streaming
    MAX_TOOL_ITERATIONS = 20
    TOOL_TIMEOUT_SECONDS = 30

    def initialize(client:, model:, max_tokens:, temperature:, system_prompt:,
                   tools:, thinking:, output_schema:, logger: nil)
      @client        = client
      @model         = model
      @max_tokens    = max_tokens
      @temperature   = temperature
      @system_prompt = system_prompt
      @tools         = tools
      @thinking      = thinking
      @output_schema = output_schema
      @logger        = logger
      @prior_messages = []
    end

    def add_messages(messages)
      @prior_messages = messages
      self
    end

    # Runs a streaming converse call, looping automatically on tool_use until the model stops.
    def stream(prompt, &block)
      response = Response.new

      message = build_user_message(prompt)
      response.add_message(message)
      log(:info, "Streaming query to #{@model}")

      iterations = 0

      loop do
        iterations += 1
        if iterations > MAX_TOOL_ITERATIONS
          log(:error, "Tool iteration limit (#{MAX_TOOL_ITERATIONS}) exceeded")
          raise ToolError,
                "Maximum tool iteration depth (#{MAX_TOOL_ITERATIONS}) exceeded"
        end

        log(:info, "Starting iteration #{iterations}")
        state = stream_converse(response.messages, &block)
        response.add_usage(state.usage)

        if state.stop_reason == 'tool_use' && !state.tool_uses.empty?
          tool_names = state.tool_uses.map { |tu| tu[:name] }.join(', ')
          log(:info, "Model requested tool_use: #{tool_names}")
          handle_tool_use(response, state)
        else
          response.set_text(state.accumulated_text)
          unless state.accumulated_text.empty? && state.reasoning_blocks.empty?
            message = build_assistant_message(state)
            response.add_message(message)
          end
          break
        end
      end

      log(:info, "Completed in #{iterations} iteration(s) " \
                 "(input_tokens=#{response.input_tokens}, output_tokens=#{response.output_tokens})")

      response
    end

    StreamState = Struct.new(
      :accumulated_text, :tool_uses, :current_tool, :tool_input_buf,
      :stop_reason, :reasoning_blocks, :current_reasoning,
      :in_reasoning_block, :usage,
      keyword_init: true
    ) do
      def self.build
        new(
          accumulated_text: +'',
          tool_uses: [],
          current_tool: nil,
          tool_input_buf: +'',
          stop_reason: nil,
          reasoning_blocks: [],
          current_reasoning: nil,
          in_reasoning_block: false,
          usage: { input_tokens: 0, output_tokens: 0 }
        )
      end
    end

    private

    # -- called by stream ------------------------------------------------

    def build_user_message(prompt)
      {
        role: 'user',
        content: [{ text: prompt }]
      }
    end

    # Sends one converse_stream call and dispatches events to handlers.
    def stream_converse(in_flight_messages, &block)
      params = build_converse_params(in_flight_messages)
      state  = StreamState.build
      log(:info, "Sending #{params[:messages].size} message(s) to Bedrock")

      @client.converse_stream(params) do |stream|
        stream.on_message_start_event { |e| handle_message_start(e, &block) }
        stream.on_content_block_start_event { |e| handle_content_block_start(state, e, &block) }
        stream.on_content_block_delta_event { |e| handle_content_block_delta(state, e, &block) }
        stream.on_content_block_stop_event { |e| handle_content_block_stop(state, e, &block) }
        stream.on_message_stop_event { |e| handle_message_stop(state, e, &block) }
        stream.on_metadata_event { |e| handle_metadata(state, e, &block) }
        stream.on_internal_server_exception_event do |e|
          log(:error, e.message)
          raise InternalServerError, e.message
        end
        stream.on_model_stream_error_exception_event do |e|
          log(:error, e.message)
          raise ModelStreamError, e.message
        end
        stream.on_throttling_exception_event do |e|
          log(:warn, e.message)
          raise ThrottlingError, e.message
        end
        stream.on_validation_exception_event do |e|
          log(:error, e.message)
          raise ValidationError, e.message
        end
        stream.on_service_unavailable_exception_event do |e|
          log(:error, e.message)
          raise ServiceUnavailableError, e.message
        end
        stream.on_error_event do |e|
          log(:error, e.error_message)
          raise StreamError, e.error_message
        end
      end

      state
    end

    # -- called by stream_converse ---------------------------------------

    # Assembles the converse_stream request params from current config and messages.
    def build_converse_params(in_flight_messages)
      all_messages = @prior_messages + in_flight_messages

      params = {
        model_id: @model,
        messages: all_messages,
        inference_config: {
          max_tokens: @max_tokens,
          temperature: @temperature
        }
      }

      params[:system] = [{ text: @system_prompt }] if @system_prompt

      unless @tools.empty?
        params[:tool_config] = {
          tools: @tools.values.map(&:to_bedrock_tool_spec),
          tool_choice: { auto: {} }
        }
      end

      if @thinking
        params[:additional_model_request_fields] = {
          'thinking' => {
            'type' => 'enabled',
            'budget_tokens' => @thinking[:budget_tokens]
          }
        }
      end

      if @output_schema
        json_schema_data = @output_schema.to_json_schema
        schema_body = json_schema_data[:schema] || json_schema_data

        params[:output_config] = {
          text_format: {
            type: 'json_schema',
            structure: {
              json_schema: {
                schema: JSON.generate(schema_body),
                name: json_schema_data[:name] || 'OutputSchema',
                description: json_schema_data[:description] || 'Structured output schema'
              }
            }
          }
        }
      end

      params
    end

    def handle_message_start(_event, &block)
      block&.call(StreamChunk.new(type: :message_start))
    end

    def handle_content_block_start(state, event, &block)
      if event.start&.tool_use
        state.current_tool = {
          tool_use_id: event.start.tool_use.tool_use_id,
          name: event.start.tool_use.name
        }

        state.tool_input_buf = +''

        block&.call(StreamChunk.new(
          type: :tool_use_start,
          tool_use_id: state.current_tool[:tool_use_id],
          tool_name: state.current_tool[:name],
          content_block_index: event.content_block_index
        ))
      else
        state.in_reasoning_block = false
        state.current_reasoning = nil
      end
    end

    def handle_content_block_delta(state, event, &)
      delta = event.delta
      return unless delta

      handle_text_delta(state, delta, event, &)
      handle_tool_use_delta(state, delta, event, &)
      handle_reasoning_delta(state, delta, event, &)
    end

    # -- called by handle_content_block_delta ----------------------------

    def handle_text_delta(state, delta, event, &block)
      return unless delta.text

      state.accumulated_text << delta.text

      block&.call(StreamChunk.new(
        type: :text,
        content: delta.text,
        content_block_index: event.content_block_index
      ))
    end

    def handle_tool_use_delta(state, delta, event, &block)
      return unless delta&.tool_use

      state.tool_input_buf << (delta.tool_use.input || '')

      block&.call(StreamChunk.new(
        type: :tool_use_delta,
        content: delta.tool_use.input,
        tool_use_id: state.current_tool&.dig(:tool_use_id),
        tool_name: state.current_tool&.dig(:name),
        content_block_index: event.content_block_index
      ))
    end

    def handle_reasoning_delta(state, delta, event, &block)
      return unless delta.respond_to?(:reasoning_content) && delta.reasoning_content

      rc = delta.reasoning_content

      reasoning_text = rc.respond_to?(:text) ? rc.text : nil
      if reasoning_text
        state.in_reasoning_block = true
        state.current_reasoning ||= { text: +'', signature: nil }
        state.current_reasoning[:text] << reasoning_text

        block&.call(StreamChunk.new(
          type: :reasoning,
          content: reasoning_text,
          content_block_index: event.content_block_index
        ))
      end

      reasoning_sig = rc.respond_to?(:signature) ? rc.signature : nil
      return unless reasoning_sig

      state.in_reasoning_block = true
      state.current_reasoning ||= { text: +'', signature: nil }
      state.current_reasoning[:signature] = reasoning_sig

      block&.call(StreamChunk.new(
        type: :reasoning_signature,
        signature: reasoning_sig,
        content_block_index: event.content_block_index
      ))
    end

    # -- called by stream_converse (continued) ---------------------------

    def handle_content_block_stop(state, event, &block)
      if state.current_tool
        finalize_tool_use(state, event, &block)
      elsif state.in_reasoning_block && state.current_reasoning
        finalize_reasoning_block(state, event, &block)
      else
        block&.call(StreamChunk.new(
          type: :content_block_stop,
          content_block_index: event.content_block_index
        ))
      end
    end

    # -- called by handle_content_block_stop -----------------------------

    # Parses accumulated tool input JSON and records the completed tool_use.
    def finalize_tool_use(state, event, &block)
      input =
        if state.tool_input_buf.empty?
          {}
        else
          begin
            JSON.parse(state.tool_input_buf, symbolize_names: true)
          rescue JSON::ParserError => e
            log(:warn, "Failed to parse tool input JSON for '#{state.current_tool[:name]}': #{e.message}")
            { _raw: state.tool_input_buf, _parse_error: e.message }
          end
        end

      state.tool_uses << {
        tool_use_id: state.current_tool[:tool_use_id],
        name: state.current_tool[:name],
        input: input
      }

      state.current_tool = nil
      state.tool_input_buf = +''

      block&.call(StreamChunk.new(
        type: :tool_use_end,
        content_block_index: event.content_block_index
      ))
    end

    def finalize_reasoning_block(state, event, &block)
      state.reasoning_blocks << state.current_reasoning
      state.in_reasoning_block = false
      state.current_reasoning = nil

      block&.call(StreamChunk.new(
        type: :content_block_stop,
        content_block_index: event.content_block_index
      ))
    end

    # -- called by stream_converse (continued) ---------------------------

    def handle_message_stop(state, event, &block)
      state.stop_reason = event.stop_reason
      log(:info, "Message stopped: #{state.stop_reason}")

      block&.call(StreamChunk.new(
        type: :message_stop,
        stop_reason: state.stop_reason
      ))
    end

    def handle_metadata(state, event, &block)
      input_tok  = 0
      output_tok = 0

      if event.usage
        input_tok  = event.usage.input_tokens  || 0
        output_tok = event.usage.output_tokens || 0

        state.usage[:input_tokens]  += input_tok
        state.usage[:output_tokens] += output_tok
      end

      block&.call(StreamChunk.new(
        type: :metadata,
        usage: state.usage.dup,
        input_tokens: input_tok,
        output_tokens: output_tok
      ))
    end

    # -- called by stream (continued) ------------------------------------

    # Records the assistant tool_use message, executes tools, and appends results.
    def handle_tool_use(response, state)
      message = build_assistant_message(state)
      response.add_message(message)

      tool_results = execute_tools(state.tool_uses)

      message = build_tool_result_message(tool_results)
      response.add_message(message)
    end

    # -- called by handle_tool_use ---------------------------------------

    # Builds an assistant message with reasoning blocks, text, and optional tool_use blocks.
    def build_assistant_message(state)
      content = []

      state.reasoning_blocks.each do |rb|
        block = { reasoning_content: { reasoning_text: { text: rb[:text] } } }
        block[:reasoning_content][:reasoning_text][:signature] = rb[:signature] if rb[:signature]
        content << block
      end

      content << { text: state.accumulated_text } unless state.accumulated_text.empty?

      state.tool_uses.each do |tu|
        content << {
          tool_use: {
            tool_use_id: tu[:tool_use_id],
            name: tu[:name],
            input: tu[:input]
          }
        }
      end

      { role: 'assistant', content: content }
    end

    def execute_tools(tool_uses)
      if tool_uses.size == 1
        tu = tool_uses.first
        result = execute_single_tool(tu)
        [result]
      else
        log(:info, "Executing #{tool_uses.size} tools in parallel")
        futures = tool_uses.map do |tu|
          Concurrent::Future.execute do
            execute_single_tool(tu)
          end
        end

        futures.zip(tool_uses).map do |future, tu|
          future.wait(TOOL_TIMEOUT_SECONDS)

          if future.fulfilled?
            future.value
          else
            # This branch handles two rare cases:
            # 1. The tool raised a non-StandardError exception (e.g. SystemStackError)
            #    -- execute_single_tool only rescues StandardError, so the future is rejected.
            # 2. The tool timed out (infinite loop/deadlock) -- future is still pending,
            #    so future.reason is nil.
            reason = future.reason
            error_msg = if reason
                          "Error executing tool '#{tu[:name]}': #{reason.message}"
                        else
                          "Error: tool '#{tu[:name]}' timed out after #{TOOL_TIMEOUT_SECONDS}s"
                        end
            log(:error, error_msg)
            {
              tool_use_id: tu[:tool_use_id],
              content: [{ text: error_msg }],
              status: 'error'
            }
          end
        end
      end
    end

    # -- called by execute_tools -----------------------------------------

    def execute_single_tool(tool_use)
      tool = @tools[tool_use[:name]]
      unless tool
        log(:warn, "Unknown tool '#{tool_use[:name]}'")
        return {
          tool_use_id: tool_use[:tool_use_id],
          content: [{ text: "Error: Unknown tool '#{tool_use[:name]}'" }],
          status: 'error'
        }
      end

      input = tool_use[:input]

      if input.key?(:_parse_error)
        log(:error, "Skipping tool '#{tool_use[:name]}' due to malformed input: #{input[:_parse_error]}")
        return {
          tool_use_id: tool_use[:tool_use_id],
          content: [{ text: "Error: malformed tool input JSON for '#{tool_use[:name]}': #{input[:_parse_error]}" }],
          status: 'error'
        }
      end

      log(:info, "Executing tool '#{tool_use[:name]}' with args: #{input.inspect}")

      begin
        result = tool.execute(**input)

        result_content =
          case result
          when Hash
            [{ json: json_safe(result) }]
          when Array
            [{ json: json_safe({ items: result }) }]
          when String
            [{ text: result }]
          else
            [{ text: result.to_s }]
          end

        {
          tool_use_id: tool_use[:tool_use_id],
          content: result_content,
          status: 'success'
        }.tap { log(:info, "Tool '#{tool_use[:name]}' completed successfully") }
      rescue StandardError => e
        log(:error, "Tool '#{tool_use[:name]}' raised: #{e.message}")
        {
          tool_use_id: tool_use[:tool_use_id],
          content: [{ text: "Error executing tool '#{tool_use[:name]}': #{e.message}" }],
          status: 'error'
        }
      end
    end

    # Converts a Hash/Array to pure JSON-safe primitives by round-tripping
    # through JSON. This ensures objects like BSON::ObjectId or
    # ActiveSupport::TimeWithZone are serialized to strings.
    def json_safe(obj)
      JSON.parse(JSON.generate(obj), symbolize_names: true)
    end

    # -- called by handle_tool_use (continued) ---------------------------

    # Wraps tool results in a user message for the next converse call.
    def build_tool_result_message(results)
      content = results.map do |r|
        {
          tool_result: {
            tool_use_id: r[:tool_use_id],
            content: r[:content],
            status: r[:status]
          }
        }
      end

      { role: 'user', content: content }
    end

    def log(level, message)
      @logger&.send(level, "[BedrockAi] #{message}")
    end
  end
end
