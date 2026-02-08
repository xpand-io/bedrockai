# frozen_string_literal: true

class BedrockAi
  class Response
    attr_reader :text, :messages, :input_tokens, :output_tokens

    def initialize(text: '', messages: [], input_tokens: 0, output_tokens: 0)
      @text          = (+(text || ''))
      @messages      = messages.dup
      @input_tokens  = input_tokens
      @output_tokens = output_tokens
    end

    def set_text(str)
      @text = (+(str || ''))
    end

    def add_message(message)
      @messages << message
    end

    def add_usage(usage)
      return if usage.nil?

      @input_tokens  += usage[:input_tokens].to_i
      @output_tokens += usage[:output_tokens].to_i
    end

    def total_tokens
      @input_tokens + @output_tokens
    end

    def to_s
      @text
    end

    def inspect
      "#<#{self.class} text=#{@text.length} chars, " \
        "messages=#{@messages.size}, " \
        "tokens=#{@input_tokens}in/#{@output_tokens}out>"
    end
  end
end
