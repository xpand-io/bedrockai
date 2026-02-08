# frozen_string_literal: true

require 'spec_helper'
require 'ruby_llm/schema'

# Tests for the converse_params building logic, verifying that thinking
# and structured output params are correctly assembled.
RSpec.describe BedrockAi::Streaming, 'converse params' do
  let(:mock_client) { instance_double(Aws::BedrockRuntime::Client) }
  let(:llm) { BedrockAi.new(model: 'anthropic.claude4.5') }

  # Build params via Streaming. Prior messages are set via add_messages,
  # then we call the private build_converse_params with empty in-flight messages.
  def build_params(llm)
    streaming = llm.send(:build_streaming)
    streaming.add_messages(llm.send(:messages))
    streaming.send(:build_converse_params, [])
  end

  # Helper to add a single user message to the LLM for param-building tests.
  def add_user_message(llm, text)
    response = BedrockAi::Response.new
    response.add_message({ role: 'user', content: [{ text: text }] })
    llm.add_response(response)
  end

  describe 'base params' do
    before { add_user_message(llm, 'hello') }

    it 'includes model_id and inference_config' do
      params = build_params(llm)
      expect(params[:model_id]).to eq('anthropic.claude4.5')
      expect(params[:inference_config][:max_tokens]).to eq(4096)
      expect(params[:inference_config][:temperature]).to eq(0.5)
    end

    it 'does not include system when not set' do
      params = build_params(llm)
      expect(params).not_to have_key(:system)
    end

    it 'includes system when set' do
      llm.set_system_prompt('Be helpful')
      params = build_params(llm)
      expect(params[:system]).to eq([{ text: 'Be helpful' }])
    end

    it 'does not include tool_config when no tools' do
      params = build_params(llm)
      expect(params).not_to have_key(:tool_config)
    end
  end

  describe 'thinking params' do
    before do
      add_user_message(llm, 'think')
      llm.set_temperature(1.0)
    end

    it 'does not include thinking fields when disabled' do
      params = build_params(llm)
      expect(params).not_to have_key(:additional_model_request_fields)
    end

    it 'includes thinking config when enabled' do
      llm.enable_thinking(budget_tokens: 8_000)
      params = build_params(llm)

      expect(params[:additional_model_request_fields]).to eq({
        'thinking' => {
          'type' => 'enabled',
          'budget_tokens' => 8_000
        }
      })
    end

    it 'removes thinking config after disable' do
      llm.enable_thinking(budget_tokens: 8_000)
      llm.disable_thinking
      params = build_params(llm)
      expect(params).not_to have_key(:additional_model_request_fields)
    end
  end

  describe 'structured output params' do
    let(:schema_class) do
      Class.new(RubyLLM::Schema) do
        name('PersonOutput')
        description 'A person'
        string :name, description: 'Full name'
        integer :age
      end
    end

    before { add_user_message(llm, 'extract') }

    it 'does not include output_config when no schema' do
      params = build_params(llm)
      expect(params).not_to have_key(:output_config)
    end

    it 'includes output_config when schema is set' do
      llm.set_output_schema(schema_class.new)
      params = build_params(llm)

      expect(params[:output_config]).to have_key(:text_format)
      text_format = params[:output_config][:text_format]
      expect(text_format[:type]).to eq('json_schema')
      expect(text_format[:structure][:json_schema][:name]).to eq('PersonOutput')
      expect(text_format[:structure][:json_schema][:schema]).to be_a(String)

      # Verify the schema is valid JSON
      parsed = JSON.parse(text_format[:structure][:json_schema][:schema])
      expect(parsed['type']).to eq('object')
      expect(parsed['properties']).to have_key('name')
      expect(parsed['properties']).to have_key('age')
    end

    it 'removes output_config when schema cleared' do
      llm.set_output_schema(schema_class.new)
      llm.set_output_schema(nil)
      params = build_params(llm)
      expect(params).not_to have_key(:output_config)
    end
  end

  describe 'tool config params' do
    let(:tool_class) do
      Class.new(BedrockAi::Tool) do
        description 'Search things'

        params do
          string :q, description: 'Query'
        end

        def execute(**)
          { result: 'ok' }
        end
      end
    end

    before { add_user_message(llm, 'search') }

    it 'includes tool_config when tools are registered' do
      stub_const('Search', tool_class)
      llm.add_tool(Search.new)
      params = build_params(llm)

      expect(params[:tool_config][:tools]).to be_an(Array)
      expect(params[:tool_config][:tools].size).to eq(1)
      expect(params[:tool_config][:tools].first[:tool_spec][:name]).to eq('search')
      expect(params[:tool_config][:tool_choice]).to eq({ auto: {} })
    end
  end

  describe 'tool result serialization' do
    def build_streaming(tools)
      BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: tools,
        thinking: nil,
        output_schema: nil
      )
    end

    def execute_tool(streaming, name:, input: {})
      streaming.send(:execute_single_tool, {
        tool_use_id: 'tu_001',
        name: name,
        input: input
      })
    end

    it 'returns json content for Hash results' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Returns a hash'
        def execute(**)
          { name: 'Alice', age: 30 }
        end
      end

      stub_const('HashTool', tool_class)
      streaming = build_streaming({ 'hash_tool' => HashTool.new })
      result = execute_tool(streaming, name: 'hash_tool')

      expect(result[:status]).to eq('success')
      json = result[:content].first[:json]
      expect(json).to eq({ name: 'Alice', age: 30 })
    end

    it 'wraps Array results in an items key' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Returns an array'
        def execute(**)
          [{ name: 'Alice' }, { name: 'Bob' }]
        end
      end

      stub_const('ArrayTool', tool_class)
      streaming = build_streaming({ 'array_tool' => ArrayTool.new })
      result = execute_tool(streaming, name: 'array_tool')

      expect(result[:status]).to eq('success')
      json = result[:content].first[:json]
      expect(json).to have_key(:items)
      expect(json[:items]).to eq([{ name: 'Alice' }, { name: 'Bob' }])
    end

    it 'returns text content for String results' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Returns a string'
        def execute(**)
          'done'
        end
      end

      stub_const('StringTool', tool_class)
      streaming = build_streaming({ 'string_tool' => StringTool.new })
      result = execute_tool(streaming, name: 'string_tool')

      expect(result[:status]).to eq('success')
      expect(result[:content]).to eq([{ text: 'done' }])
    end

    it 'converts non-primitive values to JSON-safe types' do
      custom_id = Object.new
      def custom_id.to_json(*)
        '"custom_id_123"'
      end

      tool_class = Class.new(BedrockAi::Tool) do
        define_method(:execute) do |**|
          { id: custom_id, label: 'test' }
        end

        description 'Returns non-primitive values'
      end

      stub_const('CustomTool', tool_class)
      streaming = build_streaming({ 'custom_tool' => CustomTool.new })
      result = execute_tool(streaming, name: 'custom_tool')

      expect(result[:status]).to eq('success')
      json = result[:content].first[:json]
      expect(json[:id]).to eq('custom_id_123')
      expect(json[:label]).to eq('test')
    end

    it 'converts nested non-primitive values in arrays' do
      custom_id = Object.new
      def custom_id.to_json(*)
        '"id_abc"'
      end

      tool_class = Class.new(BedrockAi::Tool) do
        define_method(:execute) do |**|
          { users: [{ id: custom_id, name: 'Alice' }] }
        end

        description 'Nested non-primitives'
      end

      stub_const('NestedTool', tool_class)
      streaming = build_streaming({ 'nested_tool' => NestedTool.new })
      result = execute_tool(streaming, name: 'nested_tool')

      json = result[:content].first[:json]
      expect(json[:users].first[:id]).to eq('id_abc')
      expect(json[:users].first[:name]).to eq('Alice')
    end

    it 'returns json with symbol keys' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Returns a hash'
        def execute(**)
          { name: 'Alice' }
        end
      end

      stub_const('SymKeyTool', tool_class)
      streaming = build_streaming({ 'sym_key_tool' => SymKeyTool.new })
      result = execute_tool(streaming, name: 'sym_key_tool')

      json = result[:content].first[:json]
      expect(json.keys).to all(be_a(Symbol))
    end

    it 'returns an error for unknown tools' do
      streaming = build_streaming({})
      result = execute_tool(streaming, name: 'missing')

      expect(result[:status]).to eq('error')
      expect(result[:content].first[:text]).to include('Unknown tool')
    end

    it 'returns an error when execute raises' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Raises an error'
        def execute(**)
          raise 'something broke'
        end
      end

      stub_const('BrokenTool', tool_class)
      streaming = build_streaming({ 'broken_tool' => BrokenTool.new })
      result = execute_tool(streaming, name: 'broken_tool')

      expect(result[:status]).to eq('error')
      expect(result[:content].first[:text]).to include('something broke')
    end

    it 'converts other return types to text via to_s' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Returns a number'
        def execute(**)
          42
        end
      end

      stub_const('NumTool', tool_class)
      streaming = build_streaming({ 'num_tool' => NumTool.new })
      result = execute_tool(streaming, name: 'num_tool')

      expect(result[:status]).to eq('success')
      expect(result[:content]).to eq([{ text: '42' }])
    end
  end

  describe 'stream response text' do
    let(:tool_class) do
      Class.new(BedrockAi::Tool) do
        description 'A tool'
        def execute(**)
          { result: 'ok' }
        end
      end
    end

    def build_streaming(tools = {})
      BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: tools,
        thinking: nil,
        output_schema: nil
      )
    end

    def make_state(text:, stop_reason:, tool_uses: [], usage: { input_tokens: 10, output_tokens: 5 })
      BedrockAi::Streaming::StreamState.new(
        accumulated_text: (+text),
        tool_uses: tool_uses,
        current_tool: nil,
        tool_input_buf: +'',
        stop_reason: stop_reason,
        reasoning_blocks: [],
        current_reasoning: nil,
        in_reasoning_block: false,
        usage: usage
      )
    end

    it 'contains only the final response text, not interim tool-use text' do
      stub_const('TestTool', tool_class)
      tool = TestTool.new
      streaming = build_streaming({ 'test_tool' => tool })

      tool_use_state = make_state(
        text: 'Let me look that up...',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'test_tool', input: {} }],
        usage: { input_tokens: 10, output_tokens: 5 }
      )

      final_state = make_state(
        text: 'The answer is 42.',
        stop_reason: 'end_turn',
        usage: { input_tokens: 20, output_tokens: 15 }
      )

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('What is the answer?')

      expect(response.text).to eq('The answer is 42.')
    end

    it 'accumulates usage across all iterations' do
      stub_const('TestTool', tool_class)
      tool = TestTool.new
      streaming = build_streaming({ 'test_tool' => tool })

      tool_use_state = make_state(
        text: 'Checking...',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'test_tool', input: {} }],
        usage: { input_tokens: 10, output_tokens: 5 }
      )

      final_state = make_state(
        text: 'Done.',
        stop_reason: 'end_turn',
        usage: { input_tokens: 20, output_tokens: 15 }
      )

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('Do it')

      expect(response.input_tokens).to eq(30)
      expect(response.output_tokens).to eq(20)
    end

    it 'works with a simple response without tool calls' do
      streaming = build_streaming

      final_state = make_state(
        text: 'Hello!',
        stop_reason: 'end_turn',
        usage: { input_tokens: 5, output_tokens: 3 }
      )

      allow(streaming).to receive(:stream_converse).and_return(final_state)

      response = streaming.stream('Hi')

      expect(response.text).to eq('Hello!')
      expect(response.input_tokens).to eq(5)
      expect(response.output_tokens).to eq(3)
    end

    it 'contains only final text after multiple tool-use iterations' do
      stub_const('TestTool', tool_class)
      tool = TestTool.new
      streaming = build_streaming({ 'test_tool' => tool })

      first_tool_state = make_state(
        text: 'First, let me check...',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'test_tool', input: {} }]
      )

      second_tool_state = make_state(
        text: 'Now let me verify...',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_2', name: 'test_tool', input: {} }]
      )

      final_state = make_state(
        text: 'The verified answer is 42.',
        stop_reason: 'end_turn'
      )

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        case call_count
        when 1 then first_tool_state
        when 2 then second_tool_state
        else final_state
        end
      end

      response = streaming.stream('Verify the answer')

      expect(response.text).to eq('The verified answer is 42.')
    end

    it 'sets empty text when final iteration has no text' do
      stub_const('TestTool', tool_class)
      tool = TestTool.new
      streaming = build_streaming({ 'test_tool' => tool })

      tool_use_state = make_state(
        text: 'Thinking...',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'test_tool', input: {} }]
      )

      final_state = make_state(
        text: '',
        stop_reason: 'end_turn'
      )

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('Do something')

      expect(response.text).to eq('')
    end
  end

  describe 'logging' do
    let(:logger) { instance_double('Logger') }

    before do
      allow(logger).to receive(:debug)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
    end

    let(:tool_class) do
      Class.new(BedrockAi::Tool) do
        description 'A tool'
        def execute(**)
          { result: 'ok' }
        end
      end
    end

    def build_streaming(tools = {})
      BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: tools,
        thinking: nil,
        output_schema: nil,
        logger: logger
      )
    end

    def make_state(text:, stop_reason:, tool_uses: [], usage: { input_tokens: 10, output_tokens: 5 })
      BedrockAi::Streaming::StreamState.new(
        accumulated_text: (+text),
        tool_uses: tool_uses,
        current_tool: nil,
        tool_input_buf: +'',
        stop_reason: stop_reason,
        reasoning_blocks: [],
        current_reasoning: nil,
        in_reasoning_block: false,
        usage: usage
      )
    end

    it 'logs stream start and completion' do
      streaming = build_streaming

      final_state = make_state(text: 'Hello!', stop_reason: 'end_turn', usage: { input_tokens: 5, output_tokens: 3 })
      allow(streaming).to receive(:stream_converse).and_return(final_state)

      expect(logger).to receive(:info).with(/Streaming query to anthropic\.claude4\.5/)
      expect(logger).to receive(:info).with(/Completed in 1 iteration.*input_tokens=5.*output_tokens=3/)

      streaming.stream('Hi')
    end

    it 'logs tool execution' do
      stub_const('LogTestTool', tool_class)
      tool = LogTestTool.new
      streaming = build_streaming({ 'log_test_tool' => tool })

      tool_use_state = make_state(
        text: 'Checking...',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'log_test_tool', input: {} }]
      )
      final_state = make_state(text: 'Done.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      allow(logger).to receive(:info)
      expect(logger).to receive(:info).with(/Executing tool 'log_test_tool' with args:/)

      streaming.stream('Do it')
    end

    it 'logs a warning for unknown tools' do
      streaming = build_streaming

      tool_use_state = make_state(
        text: '',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'missing', input: {} }]
      )
      final_state = make_state(text: 'Done.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      expect(logger).to receive(:warn).with(/Unknown tool 'missing'/)

      streaming.stream('Do it')
    end

    it 'logs errors from tool execution' do
      broken_class = Class.new(BedrockAi::Tool) do
        description 'Broken'
        def execute(**)
          raise 'kaboom'
        end
      end

      stub_const('BrokenLogTool', broken_class)
      streaming = build_streaming({ 'broken_log_tool' => BrokenLogTool.new })

      tool_use_state = make_state(
        text: '',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'broken_log_tool', input: {} }]
      )
      final_state = make_state(text: 'Done.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      expect(logger).to receive(:error).with(/Tool 'broken_log_tool' raised: kaboom/)

      streaming.stream('Do it')
    end

    it 'works without a logger' do
      streaming = BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: {},
        thinking: nil,
        output_schema: nil
      )

      final_state = make_state(text: 'Hello!', stop_reason: 'end_turn')
      allow(streaming).to receive(:stream_converse).and_return(final_state)

      expect { streaming.stream('Hi') }.not_to raise_error
    end
  end

  describe 'parallel tool execution' do
    def build_streaming(tools)
      BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: tools,
        thinking: nil,
        output_schema: nil
      )
    end

    def make_state(text:, stop_reason:, tool_uses: [], usage: { input_tokens: 10, output_tokens: 5 })
      BedrockAi::Streaming::StreamState.new(
        accumulated_text: (+text),
        tool_uses: tool_uses,
        current_tool: nil,
        tool_input_buf: +'',
        stop_reason: stop_reason,
        reasoning_blocks: [],
        current_reasoning: nil,
        in_reasoning_block: false,
        usage: usage
      )
    end

    it 'executes multiple tools and returns all results' do
      tool_a = Class.new(BedrockAi::Tool) do
        description 'Tool A'
        def execute(**)
          { a: 'result_a' }
        end
      end

      tool_b = Class.new(BedrockAi::Tool) do
        description 'Tool B'
        def execute(**)
          { b: 'result_b' }
        end
      end

      stub_const('ToolA', tool_a)
      stub_const('ToolB', tool_b)

      tools = { 'tool_a' => ToolA.new, 'tool_b' => ToolB.new }
      streaming = build_streaming(tools)

      tool_use_state = make_state(
        text: 'Using tools...',
        stop_reason: 'tool_use',
        tool_uses: [
          { tool_use_id: 'tu_1', name: 'tool_a', input: {} },
          { tool_use_id: 'tu_2', name: 'tool_b', input: {} }
        ]
      )

      final_state = make_state(text: 'Both done.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('Use both tools')

      expect(response.text).to eq('Both done.')
      # Should have 4 messages: user, assistant (tool_use), user (tool_results), assistant (final)
      expect(response.messages.size).to eq(4)

      tool_result_msg = response.messages[2]
      expect(tool_result_msg[:role]).to eq('user')
      results = tool_result_msg[:content]
      expect(results.size).to eq(2)
      expect(results.map { |r| r[:tool_result][:status] }).to all(eq('success'))
    end

    it 'handles errors in one tool without affecting others' do
      good_tool = Class.new(BedrockAi::Tool) do
        description 'Good tool'
        def execute(**)
          { ok: true }
        end
      end

      bad_tool = Class.new(BedrockAi::Tool) do
        description 'Bad tool'
        def execute(**)
          raise 'kaboom'
        end
      end

      stub_const('GoodParTool', good_tool)
      stub_const('BadParTool', bad_tool)

      tools = { 'good_par_tool' => GoodParTool.new, 'bad_par_tool' => BadParTool.new }
      streaming = build_streaming(tools)

      tool_use_state = make_state(
        text: '',
        stop_reason: 'tool_use',
        tool_uses: [
          { tool_use_id: 'tu_1', name: 'good_par_tool', input: {} },
          { tool_use_id: 'tu_2', name: 'bad_par_tool', input: {} }
        ]
      )

      final_state = make_state(text: 'Done anyway.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('Use both')

      expect(response.text).to eq('Done anyway.')
      tool_result_msg = response.messages[2]
      results = tool_result_msg[:content]
      statuses = results.map { |r| r[:tool_result][:status] }
      expect(statuses).to contain_exactly('success', 'error')
    end

    it 'preserves exception messages from rejected futures' do
      good_tool = Class.new(BedrockAi::Tool) do
        description 'Good tool'
        def execute(**)
          { ok: true }
        end
      end

      bad_tool = Class.new(BedrockAi::Tool) do
        description 'Bad tool'
        def execute(**)
          raise 'specific error message'
        end
      end

      stub_const('GoodFutureTool', good_tool)
      stub_const('BadFutureTool', bad_tool)

      tools = { 'good_future_tool' => GoodFutureTool.new, 'bad_future_tool' => BadFutureTool.new }
      streaming = build_streaming(tools)

      tool_use_state = make_state(
        text: '',
        stop_reason: 'tool_use',
        tool_uses: [
          { tool_use_id: 'tu_1', name: 'good_future_tool', input: {} },
          { tool_use_id: 'tu_2', name: 'bad_future_tool', input: {} }
        ]
      )

      final_state = make_state(text: 'Done.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('Use both')

      tool_result_msg = response.messages[2]
      error_result = tool_result_msg[:content].find { |r| r[:tool_result][:status] == 'error' }
      expect(error_result[:tool_result][:content].first[:text]).to include('specific error message')
    end
  end

  describe 'tool iteration limit' do
    def build_streaming(tools = {})
      BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: tools,
        thinking: nil,
        output_schema: nil
      )
    end

    def make_state(text:, stop_reason:, tool_uses: [], usage: { input_tokens: 1, output_tokens: 1 })
      BedrockAi::Streaming::StreamState.new(
        accumulated_text: (+text),
        tool_uses: tool_uses,
        current_tool: nil,
        tool_input_buf: +'',
        stop_reason: stop_reason,
        reasoning_blocks: [],
        current_reasoning: nil,
        in_reasoning_block: false,
        usage: usage
      )
    end

    it 'raises ToolError after MAX_TOOL_ITERATIONS' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'Looping tool'
        def execute(**)
          { ok: true }
        end
      end

      stub_const('LoopTool', tool_class)
      streaming = build_streaming({ 'loop_tool' => LoopTool.new })

      # Always return tool_use, never end_turn
      tool_use_state = make_state(
        text: '',
        stop_reason: 'tool_use',
        tool_uses: [{ tool_use_id: 'tu_1', name: 'loop_tool', input: {} }]
      )

      allow(streaming).to receive(:stream_converse).and_return(tool_use_state)

      expect { streaming.stream('Loop forever') }.to raise_error(
        BedrockAi::ToolError, /Maximum tool iteration depth/
      )
    end
  end

  describe 'malformed tool input JSON' do
    def build_streaming(tools)
      BedrockAi::Streaming.new(
        client: mock_client,
        model: 'anthropic.claude4.5',
        max_tokens: 4096,
        temperature: 0.5,
        system_prompt: nil,
        tools: tools,
        thinking: nil,
        output_schema: nil
      )
    end

    it 'returns an error result without calling execute' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'A tool'
        def execute(**)
          raise 'Should not be called'
        end
      end

      stub_const('MalformedTool', tool_class)
      streaming = build_streaming({ 'malformed_tool' => MalformedTool.new })

      result = streaming.send(:execute_single_tool, {
        tool_use_id: 'tu_001',
        name: 'malformed_tool',
        input: { _raw: '{bad json', _parse_error: 'unexpected token' }
      })

      expect(result[:status]).to eq('error')
      expect(result[:content].first[:text]).to include('malformed tool input JSON')
      expect(result[:content].first[:text]).to include('unexpected token')
    end

    it 'does not crash during a full stream with malformed input' do
      tool_class = Class.new(BedrockAi::Tool) do
        description 'A tool'
        def execute(**)
          { ok: true }
        end
      end

      stub_const('MalformedStreamTool', tool_class)

      def make_state(text:, stop_reason:, tool_uses: [], usage: { input_tokens: 10, output_tokens: 5 })
        BedrockAi::Streaming::StreamState.new(
          accumulated_text: (+text),
          tool_uses: tool_uses,
          current_tool: nil,
          tool_input_buf: +'',
          stop_reason: stop_reason,
          reasoning_blocks: [],
          current_reasoning: nil,
          in_reasoning_block: false,
          usage: usage
        )
      end

      streaming = build_streaming({ 'malformed_stream_tool' => MalformedStreamTool.new })

      tool_use_state = make_state(
        text: '',
        stop_reason: 'tool_use',
        tool_uses: [{
          tool_use_id: 'tu_1',
          name: 'malformed_stream_tool',
          input: { _raw: '{bad', _parse_error: 'parse error' }
        }]
      )

      final_state = make_state(text: 'Recovered.', stop_reason: 'end_turn')

      call_count = 0
      allow(streaming).to receive(:stream_converse) do
        call_count += 1
        call_count == 1 ? tool_use_state : final_state
      end

      response = streaming.stream('Do it')

      expect(response.text).to eq('Recovered.')
      tool_result_msg = response.messages[2]
      expect(tool_result_msg[:content].first[:tool_result][:status]).to eq('error')
    end
  end
end
