# frozen_string_literal: true

require 'spec_helper'
require 'ruby_llm/schema'

RSpec.describe BedrockAi do
  let(:llm) { BedrockAi.new(model: 'anthropic.claude4.5') }

  describe '#initialize' do
    it 'starts with no conversation history' do
      expect(llm.send(:messages)).to eq([])
    end

    it 'rejects nil model' do
      expect { BedrockAi.new(model: nil) }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'rejects empty model' do
      expect { BedrockAi.new(model: '') }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'rejects whitespace-only model' do
      expect { BedrockAi.new(model: '   ') }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'rejects non-string model' do
      expect { BedrockAi.new(model: 123) }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end
  end

  describe '#set_temperature' do
    it 'accepts valid temperature values' do
      expect(llm.set_temperature(0.5)).to eq(llm)
    end

    it 'accepts boundary values 0.0 and 1.0' do
      expect { llm.set_temperature(0.0) }.not_to raise_error
      expect { llm.set_temperature(1.0) }.not_to raise_error
    end

    it 'rejects values below 0.0' do
      expect { llm.set_temperature(-0.1) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects values above 1.0' do
      expect { llm.set_temperature(1.1) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects non-numeric values' do
      expect { llm.set_temperature('hot') }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'returns self for chaining' do
      expect(llm.set_temperature(0.5)).to be(llm)
    end
  end

  describe '#set_max_tokens' do
    it 'accepts a valid positive integer' do
      expect(llm.set_max_tokens(8192)).to be(llm)
    end

    it 'rejects zero' do
      expect { llm.set_max_tokens(0) }.to raise_error(BedrockAi::ConfigurationError, /positive integer/)
    end

    it 'rejects negative values' do
      expect { llm.set_max_tokens(-100) }.to raise_error(BedrockAi::ConfigurationError, /positive integer/)
    end

    it 'rejects floats' do
      expect { llm.set_max_tokens(100.5) }.to raise_error(BedrockAi::ConfigurationError, /positive integer/)
    end

    it 'rejects non-numeric values' do
      expect { llm.set_max_tokens('big') }.to raise_error(BedrockAi::ConfigurationError, /positive integer/)
    end

    it 'returns self for chaining' do
      expect(llm.set_max_tokens(2048)).to be(llm)
    end

    it 'propagates to converse params' do
      llm.set_max_tokens(2048)
      streaming = llm.send(:build_streaming)
      params = streaming.send(:build_converse_params, [])
      expect(params[:inference_config][:max_tokens]).to eq(2048)
    end
  end

  describe '#set_system_prompt' do
    it 'accepts a valid string' do
      expect(llm.set_system_prompt('Be helpful')).to eq(llm)
    end

    it 'rejects nil' do
      expect { llm.set_system_prompt(nil) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects empty strings' do
      expect { llm.set_system_prompt('') }.to raise_error(BedrockAi::ConfigurationError)
      expect { llm.set_system_prompt('   ') }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects non-string values' do
      expect { llm.set_system_prompt(123) }.to raise_error(BedrockAi::ConfigurationError)
      expect { llm.set_system_prompt(:symbol) }.to raise_error(BedrockAi::ConfigurationError)
      expect { llm.set_system_prompt(['array']) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'returns self for chaining' do
      expect(llm.set_system_prompt('test')).to be(llm)
    end
  end

  describe '#enable_thinking' do
    before { llm.set_temperature(1.0) }

    it 'accepts valid budget_tokens' do
      expect(llm.enable_thinking(budget_tokens: 5_000)).to be(llm)
    end

    it 'rejects zero budget' do
      expect { llm.enable_thinking(budget_tokens: 0) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects negative budget' do
      expect { llm.enable_thinking(budget_tokens: -100) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects non-integer budget' do
      expect { llm.enable_thinking(budget_tokens: 5.5) }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'rejects temperature other than 1.0' do
      other_llm = BedrockAi.new(model: 'anthropic.claude4.5')
      other_llm.set_temperature(0.7)
      expect { other_llm.enable_thinking(budget_tokens: 5_000) }.to raise_error(
        BedrockAi::ConfigurationError, /Temperature must be 1.0/
      )
    end

    it 'rejects changing temperature away from 1.0 while thinking is enabled' do
      llm.enable_thinking(budget_tokens: 5_000)
      expect { llm.set_temperature(0.5) }.to raise_error(
        BedrockAi::ConfigurationError, /Temperature must be 1.0/
      )
    end

    it 'returns self for chaining' do
      expect(llm.enable_thinking(budget_tokens: 1000)).to be(llm)
    end
  end

  describe '#disable_thinking' do
    it 'returns self for chaining' do
      llm.set_temperature(1.0)
      llm.enable_thinking(budget_tokens: 1000)
      expect(llm.disable_thinking).to be(llm)
    end
  end

  describe '#set_output_schema' do
    let(:schema_class) do
      Class.new(RubyLLM::Schema) do
        string :name, description: 'Full name'
        integer :age, description: 'Age in years'
      end
    end

    it 'accepts a valid schema instance' do
      expect(llm.set_output_schema(schema_class.new)).to be(llm)
    end

    it 'accepts nil to clear the schema' do
      llm.set_output_schema(schema_class.new)
      expect(llm.set_output_schema(nil)).to be(llm)
    end

    it 'rejects objects without to_json_schema' do
      expect { llm.set_output_schema('not a schema') }.to raise_error(BedrockAi::ConfigurationError)
    end

    it 'returns self for chaining' do
      expect(llm.set_output_schema(schema_class.new)).to be(llm)
    end
  end

  describe '#add_tool' do
    let(:tool_class) do
      Class.new(BedrockAi::Tool) do
        description 'Search for users'

        params do
          string :query, description: 'Search query'
        end

        def execute(query:)
          { results: [{ name: query }] }
        end
      end
    end

    it 'accepts a valid tool' do
      expect(llm.add_tool(tool_class.new)).to be(llm)
    end

    it 'rejects non-Tool objects' do
      expect { llm.add_tool(Object.new) }.to raise_error(BedrockAi::ConfigurationError, /BedrockAi::Tool/)
      expect { llm.add_tool('string') }.to raise_error(BedrockAi::ConfigurationError, /BedrockAi::Tool/)
    end

    it 'rejects duplicate tool names' do
      stub_const('DupTool', tool_class)
      llm.add_tool(DupTool.new)
      expect { llm.add_tool(DupTool.new) }.to raise_error(
        BedrockAi::ConfigurationError, /already registered/
      )
    end

    it 'returns self for chaining' do
      expect(llm.add_tool(tool_class.new)).to be(llm)
    end
  end

  describe '#query' do
    let(:mock_streaming) { instance_double(BedrockAi::Streaming) }
    let(:mock_response) { BedrockAi::Response.new(text: 'Hello!') }

    before do
      allow(BedrockAi::Streaming).to receive(:new).and_return(mock_streaming)
      allow(mock_streaming).to receive(:add_messages)
      allow(mock_streaming).to receive(:stream).and_return(mock_response)
    end

    it 'rejects nil prompt' do
      expect { llm.query(nil) }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'rejects non-string prompt' do
      expect { llm.query(123) }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'rejects empty string prompt' do
      expect { llm.query('') }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'rejects whitespace-only prompt' do
      expect { llm.query('   ') }.to raise_error(BedrockAi::ConfigurationError, /non-empty string/)
    end

    it 'returns a Response' do
      result = llm.query('Hello')
      expect(result).to be_a(BedrockAi::Response)
      expect(result.text).to eq('Hello!')
    end

    it 'stores the response in conversation history' do
      llm.query('Hello')
      expect(llm.send(:instance_variable_get, :@responses).size).to eq(1)
    end

    it 'passes the block through to streaming' do
      chunks = []
      allow(mock_streaming).to receive(:stream) do |_prompt, &block|
        block&.call(:chunk1)
        block&.call(:chunk2)
        mock_response
      end

      llm.query('Hello') { |chunk| chunks << chunk }
      expect(chunks).to eq(%i[chunk1 chunk2])
    end

    it 'delegates to Streaming with prior messages' do
      # Add a prior response
      prior = BedrockAi::Response.new(
        text: 'Prior',
        messages: [
          { role: 'user', content: [{ text: 'First' }] },
          { role: 'assistant', content: [{ text: 'Prior' }] }
        ]
      )
      llm.add_response(prior)

      expect(mock_streaming).to receive(:add_messages).with(prior.messages)
      llm.query('Second')
    end

    it 'accumulates responses across multiple queries' do
      llm.query('First')

      second_response = BedrockAi::Response.new(text: 'World!')
      allow(mock_streaming).to receive(:stream).and_return(second_response)
      llm.query('Second')

      expect(llm.send(:instance_variable_get, :@responses).size).to eq(2)
    end
  end
end
