# frozen_string_literal: true

class BedrockAi
  class StreamChunk
    attr_reader :type, :content, :tool_use_id, :tool_name, :stop_reason,
                :usage, :content_block_index, :signature,
                :input_tokens, :output_tokens

    # Event types:
    #   :text               - a delta of streamed text
    #   :tool_use_start     - beginning of a tool_use block
    #   :tool_use_delta     - a delta of tool input JSON
    #   :tool_use_end       - end of a tool_use content block
    #   :message_start      - start of the assistant message
    #   :message_stop       - end of the assistant message
    #   :metadata           - token usage / latency metrics
    #   :content_block_stop - generic content block end
    #   :reasoning          - reasoning/thinking text content
    #   :reasoning_signature - signature for a reasoning block (for multi-turn)
    def initialize(type:, content: nil, tool_use_id: nil, tool_name: nil,
                   stop_reason: nil, usage: nil, content_block_index: nil,
                   signature: nil, input_tokens: nil, output_tokens: nil)
      @type               = type
      @content            = content
      @tool_use_id        = tool_use_id
      @tool_name          = tool_name
      @stop_reason        = stop_reason
      @usage              = usage
      @content_block_index = content_block_index
      @signature          = signature
      @input_tokens       = input_tokens
      @output_tokens      = output_tokens
    end

    # Returns true when this chunk carries streamed text content.
    def text?
      @type == :text
    end

    # Returns true when this chunk signals the start of a tool call.
    def tool_use_start?
      @type == :tool_use_start
    end

    # Returns true when this chunk carries a fragment of tool input JSON.
    def tool_use_delta?
      @type == :tool_use_delta
    end

    # Returns true when this chunk signals the end of a tool call.
    def tool_use_end?
      @type == :tool_use_end
    end

    # Returns true when this chunk signals the start of the assistant message.
    def message_start?
      @type == :message_start
    end

    # Returns true when this chunk signals the end of the message.
    def message_stop?
      @type == :message_stop
    end

    # Returns true when the model requested tool use as its stop reason.
    def tool_use_stop?
      @stop_reason == 'tool_use'
    end

    # Returns true when this chunk carries reasoning/thinking content.
    def reasoning?
      @type == :reasoning
    end

    # Returns true when this chunk carries a reasoning block signature.
    def reasoning_signature?
      @type == :reasoning_signature
    end

    # Returns true when this chunk carries token usage metadata.
    def metadata?
      @type == :metadata
    end

    # Returns true when this chunk signals the end of a content block.
    def content_block_stop?
      @type == :content_block_stop
    end
  end
end
