# frozen_string_literal: true

require 'ruby_llm/schema'

class BedrockAi
  class Tool
    class << self
      def description(text = nil)
        @description = text if text
        @description
      end

      def params(&)
        @schema_class = RubyLLM::Schema.create(&)
      end

      attr_reader :schema_class
    end

    # Tool name derived from class name (e.g. GetWeather -> get_weather).
    def name
      underscore(self.class.name || 'anonymous_tool')
    end

    def description
      self.class.description || "Tool: #{name}"
    end

    # Override in subclasses to implement tool logic.
    def execute(**params)
      raise NotImplementedError, "#{self.class}#execute must be implemented"
    end

    # Convert to the Bedrock tool_spec format.
    def to_bedrock_tool_spec
      {
        tool_spec: {
          name:,
          description:,
          input_schema: {
            json: input_schema
          }
        }
      }
    end

    private

    def input_schema
      schema_class = self.class.schema_class
      unless schema_class
        return {
          'type' => 'object',
          'properties' => {}
        }
      end

      schema = schema_class.new.to_json_schema
      deep_stringify(schema[:schema] || schema)
    end

    # Recursively converts all Symbol keys and values to Strings so the
    # schema is pure JSON-compatible types (required by the AWS SDK).
    def deep_stringify(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array
        obj.map { |v| deep_stringify(v) }
      when Symbol
        obj.to_s
      else
        obj
      end
    end

    def underscore(camel_cased_word)
      camel_cased_word
        .gsub('::', '_')
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
    end
  end
end
