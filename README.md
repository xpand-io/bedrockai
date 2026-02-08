# BedrockAI

A Ruby client for AWS Bedrock's Converse Streaming API with tool calling, parallel execution, extended thinking, and structured output.

## Features

- **Streaming responses** -- real-time token-by-token output via blocks
- **Tool calling** -- define tools with JSON Schema inputs; the gem handles the full tool-use loop automatically
- **Parallel tool execution** -- concurrent tool calls via `concurrent-ruby`
- **Extended thinking** -- Claude's reasoning mode with configurable token budgets
- **Structured output** -- JSON Schema-based output constraints
- **Conversation persistence** -- serialize responses to/from JSON for multi-turn workflows

## Installation

Add to your Gemfile:

```ruby
gem 'bedrockai', git: 'https://github.com/xpand-io/bedrockai.git'
```

Then run `bundle install`.

**Requirements:** Ruby >= 3.1.0, valid AWS credentials (via `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, etc.)

## Quick Start

```ruby
require 'bedrockai'

llm = BedrockAi
  .new(model: 'us.anthropic.claude-sonnet-4-20250514-v1:0')
  .set_system_prompt('You are a helpful assistant.')
  .set_temperature(0.3)

response = llm.query('What is Ruby?') do |chunk|
  print chunk.content if chunk.text?
end

puts
puts "Tokens: #{response.total_tokens}"
```

## Tool Calling

Define tools by inheriting from `BedrockAi::Tool` and implementing `execute`:

```ruby
class GetWeather < BedrockAi::Tool
  description 'Get current weather for a location'

  params do
    number :latitude,  description: 'Latitude (-90 to 90)'
    number :longitude, description: 'Longitude (-180 to 180)'
  end

  def execute(latitude:, longitude:)
    # call a weather API and return a Hash, Array, or String
    { temperature: 22.5, conditions: 'sunny' }
  end
end

llm = BedrockAi
  .new(model: 'us.anthropic.claude-sonnet-4-20250514-v1:0')
  .add_tool(GetWeather.new)

response = llm.query("What's the weather at 48.85, 2.35?") do |chunk|
  case chunk.type
  when :text           then print chunk.content
  when :tool_use_start then puts "\n[calling #{chunk.tool_name}]"
  when :tool_use_end   then puts '[done]'
  end
end
```

When the model requests multiple tools at once, they are executed in parallel using `Concurrent::Future`.

## Extended Thinking

Temperature must be set to `1.0` before enabling thinking:

```ruby
llm = BedrockAi
  .new(model: 'us.anthropic.claude-sonnet-4-20250514-v1:0')
  .set_temperature(1.0)
  .enable_thinking(budget_tokens: 10_000)

response = llm.query('Solve this step by step...') do |chunk|
  case chunk.type
  when :reasoning then print chunk.content  # thinking output
  when :text      then print chunk.content  # final answer
  end
end
```

Once thinking is enabled, temperature cannot be changed to any value other than `1.0`.

## Structured Output

```ruby
class MovieReview < RubyLLM::Schema
  string  :title,   description: 'Movie title'
  number  :rating,  description: 'Rating out of 10'
  string  :summary, description: 'Brief summary'
end

llm = BedrockAi
  .new(model: 'us.anthropic.claude-sonnet-4-20250514-v1:0')
  .set_output_schema(MovieReview.new)
```

Pass `nil` to clear the schema: `llm.set_output_schema(nil)`.

## Conversation Persistence

Responses can be restored later for multi-turn conversations:

```ruby
# Save -- store response attributes in your database
db.save(text: response.text, messages: response.messages,
        input_tokens: response.input_tokens, output_tokens: response.output_tokens)

# Restore
llm = BedrockAi.new(model: 'us.anthropic.claude-sonnet-4-20250514-v1:0')
llm.add_response(BedrockAi::Response.new(text: row.text, messages: row.messages,
                                         input_tokens: row.input_tokens,
                                         output_tokens: row.output_tokens))
llm.query('Follow-up question...') { |chunk| print chunk.content if chunk.text? }
```

## Configuration

### Constructor

```ruby
BedrockAi.new(
  model:,            # Required -- Bedrock model ID (String)
  region: nil,       # Optional -- AWS region
  credentials: nil,  # Optional -- AWS credentials object
  logger: nil        # Optional -- Logger instance (defaults to $stdout)
)
```

### Methods

| Method | Description | Default |
|---|---|---|
| `set_temperature(val)` | Sampling temperature (0.0 - 1.0) | `0.5` |
| `set_max_tokens(val)` | Maximum output tokens (positive integer) | `4096` |
| `set_system_prompt(str)` | System prompt | `nil` |
| `add_tool(tool)` | Register a `BedrockAi::Tool` instance | -- |
| `enable_thinking(budget_tokens:)` | Enable extended thinking (requires temperature = 1.0) | disabled |
| `disable_thinking` | Disable extended thinking | -- |
| `set_output_schema(schema)` | Constrain output to a JSON schema (`nil` to clear) | `nil` |
| `add_response(response)` | Restore a prior `BedrockAi::Response` for multi-turn | -- |
| `query(prompt, &block)` | Send a prompt and stream the response | -- |

All configuration methods return `self` for chaining.

## Response Object

`query` returns a `BedrockAi::Response` with the following interface:

| Method | Description |
|---|---|
| `text` | The final response text |
| `messages` | Array of conversation message hashes (user, assistant, tool_result) |
| `input_tokens` | Total input tokens consumed |
| `output_tokens` | Total output tokens consumed |
| `total_tokens` | Sum of input and output tokens |
| `to_s` | Returns the response text |

## Stream Chunk Types

Chunks yielded to the block have a `type` attribute and predicate methods:

| Type | Predicate | Description | Key Attributes |
|---|---|---|---|
| `:text` | `text?` | Streamed text delta | `content` |
| `:tool_use_start` | `tool_use_start?` | Tool call beginning | `tool_use_id`, `tool_name` |
| `:tool_use_delta` | `tool_use_delta?` | Tool input JSON fragment | `content`, `tool_use_id`, `tool_name` |
| `:tool_use_end` | -- | Tool call complete | `content_block_index` |
| `:reasoning` | `reasoning?` | Thinking/reasoning text | `content` |
| `:reasoning_signature` | `reasoning_signature?` | Reasoning block signature | `signature` |
| `:message_start` | -- | Assistant message start | -- |
| `:message_stop` | `message_stop?` | Assistant message end | `stop_reason` |
| `:metadata` | `metadata?` | Token usage metrics | `usage`, `input_tokens`, `output_tokens` |
| `:content_block_stop` | -- | Generic content block end | `content_block_index` |

Additional predicate: `tool_use_stop?` returns `true` when `stop_reason == 'tool_use'`.

## Error Handling

All errors inherit from `BedrockAi::Error`:

| Error Class | Description |
|---|---|
| `BedrockAi::ConfigurationError` | Invalid configuration (bad temperature, missing model, duplicate tool, etc.) |
| `BedrockAi::ToolError` | Tool iteration limit exceeded (max 20 iterations) |
| `BedrockAi::ApiError` | Base class for API errors |
| `BedrockAi::InternalServerError` | AWS internal server error |
| `BedrockAi::ModelStreamError` | Model stream error |
| `BedrockAi::ThrottlingError` | Request throttled |
| `BedrockAi::ValidationError` | Request validation failed |
| `BedrockAi::ServiceUnavailableError` | Service unavailable |
| `BedrockAi::StreamError` | Generic stream error |

## Development

```sh
bundle install
bundle exec rspec      # run tests
bundle exec rubocop    # run linter
```

## License

MIT
