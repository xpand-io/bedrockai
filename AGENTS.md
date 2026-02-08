# AGENTS.md

Ruby gem wrapping AWS Bedrock's Converse Streaming API.

## Commands

```sh
bundle exec rspec       # run tests
bundle exec rubocop     # run linter
```

## Architecture

- `BedrockAi` (`lib/bedrockai.rb`) -- public facade, all setters return `self`
- `Streaming` (`lib/bedrockai/streaming.rb`) -- streaming engine + automatic tool-use loop
- `Response` (`lib/bedrockai/response.rb`) -- accumulates text, messages, usage; serializable to JSON
- `Tool` (`lib/bedrockai/tool.rb`) -- wraps `RubyLLM::Schema` subclasses for Bedrock format
- `StreamChunk` (`lib/bedrockai/stream_chunk.rb`) -- typed event objects yielded during streaming

## Conventions

- All files use `# frozen_string_literal: true`
- Tests mock the AWS client via `instance_double` -- no real AWS calls
