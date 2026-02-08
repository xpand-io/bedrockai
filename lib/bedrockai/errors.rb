# frozen_string_literal: true

class BedrockAi
  # Base error class for all BedrockAi errors.
  class Error < StandardError; end

  # Raised when invalid configuration is provided (e.g. temperature, system prompt, tools).
  class ConfigurationError < Error; end

  # Raised when the tool-use loop exceeds the maximum iteration depth.
  class ToolError < Error; end

  # Base class for errors returned by the Bedrock API.
  class ApiError < Error; end

  class InternalServerError < ApiError; end
  class ModelStreamError < ApiError; end
  class ThrottlingError < ApiError; end
  class ValidationError < ApiError; end
  class ServiceUnavailableError < ApiError; end
  class StreamError < ApiError; end
end
