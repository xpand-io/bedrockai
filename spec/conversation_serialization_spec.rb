# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BedrockAi do
  let(:llm) { BedrockAi.new(model: 'anthropic.claude4.5') }

  # Builds a simple exchange (user prompt + assistant reply) as a Response.
  def simple_exchange
    BedrockAi::Response.new(
      text: 'Hi there!',
      messages: [
        { role: 'user', content: [{ text: 'Hello' }] },
        { role: 'assistant', content: [{ text: 'Hi there!' }] }
      ]
    )
  end

  # Builds a tool-call exchange as a Response.
  def tool_exchange
    BedrockAi::Response.new(
      text: "It's 18°C in London.",
      input_tokens: 50,
      output_tokens: 30,
      messages: [
        { role: 'user', content: [{ text: "What's the weather?" }] },
        {
          role: 'assistant',
          content: [
            {
              tool_use: {
                tool_use_id: 'tu_001',
                name: 'get_weather',
                input: { city: 'London' }
              }
            }
          ]
        },
        {
          role: 'user',
          content: [
            {
              tool_result: {
                tool_use_id: 'tu_001',
                content: [{ json: { temperature: 18, unit: 'celsius' } }],
                status: 'success'
              }
            }
          ]
        },
        { role: 'assistant', content: [{ text: "It's 18°C in London." }] }
      ]
    )
  end

  describe '#add_response' do
    it 'adds messages from a Response' do
      llm.add_response(simple_exchange)
      expect(llm.send(:messages).size).to eq(2)
      expect(llm.send(:messages).first).to be_a(Hash)
    end

    it 'flattens messages into the conversation history' do
      llm.add_response(simple_exchange)
      expect(llm.send(:messages).size).to eq(2)
    end

    it 'preserves message keys' do
      llm.add_response(simple_exchange)
      msg = llm.send(:messages).first
      expect(msg[:role]).to eq('user')
      expect(msg[:content].first[:text]).to eq('Hello')
    end

    it 'preserves nested tool_use keys' do
      llm.add_response(tool_exchange)
      tool_use = llm.send(:messages)[1][:content].first[:tool_use]
      expect(tool_use[:tool_use_id]).to eq('tu_001')
      expect(tool_use[:name]).to eq('get_weather')
      expect(tool_use[:input][:city]).to eq('London')
    end

    it 'preserves text and usage' do
      llm.add_response(tool_exchange)
      response = llm.send(:instance_variable_get, :@responses).last
      expect(response.text).to eq("It's 18°C in London.")
      expect(response.input_tokens).to eq(50)
      expect(response.output_tokens).to eq(30)
    end

    it 'appends to existing messages rather than replacing' do
      llm.add_response(simple_exchange)
      llm.add_response(tool_exchange)
      expect(llm.send(:messages).size).to eq(6)
    end

    it 'accepts an empty Response' do
      llm.add_response(BedrockAi::Response.new)
      expect(llm.send(:messages)).to eq([])
    end

    it 'returns self for chaining' do
      expect(llm.add_response(simple_exchange)).to be(llm)
    end

    it 'raises ConfigurationError for non-Response input' do
      expect { llm.add_response('string') }.to raise_error(BedrockAi::ConfigurationError, /Expected a Response/)
      expect { llm.add_response(nil) }.to raise_error(BedrockAi::ConfigurationError, /Expected a Response/)
      expect { llm.add_response({}) }.to raise_error(BedrockAi::ConfigurationError, /Expected a Response/)
      expect { llm.add_response([]) }.to raise_error(BedrockAi::ConfigurationError, /Expected a Response/)
    end

    it 'preserves tool result messages' do
      llm.add_response(tool_exchange)
      tool_result = llm.send(:messages)[2][:content].first[:tool_result]
      expect(tool_result[:tool_use_id]).to eq('tu_001')
      expect(tool_result[:status]).to eq('success')
      expect(tool_result[:content].first[:json][:temperature]).to eq(18)
    end

    it 'preserves reasoning blocks' do
      response = BedrockAi::Response.new(
        text: 'Here is my answer.',
        messages: [
          { role: 'user', content: [{ text: 'Think carefully' }] },
          {
            role: 'assistant',
            content: [
              {
                reasoning_content: {
                  reasoning_text: {
                    text: 'Let me think...',
                    signature: 'sig_abc123'
                  }
                }
              },
              { text: 'Here is my answer.' }
            ]
          }
        ]
      )

      llm.add_response(response)
      msg = llm.send(:messages).last
      reasoning = msg[:content].first[:reasoning_content][:reasoning_text]
      expect(reasoning[:text]).to eq('Let me think...')
      expect(reasoning[:signature]).to eq('sig_abc123')
      expect(msg[:content].last[:text]).to eq('Here is my answer.')
    end
  end

  describe 'round-trip: Response.new -> add_response' do
    it 'preserves a simple exchange through round-trip' do
      response = BedrockAi::Response.new(
        text: 'Hi!',
        messages: [
          { role: 'user', content: [{ text: 'Hello' }] },
          { role: 'assistant', content: [{ text: 'Hi!' }] }
        ]
      )

      llm.add_response(response)
      expect(llm.send(:messages).size).to eq(2)
      expect(llm.send(:messages).first[:content].first[:text]).to eq('Hello')
      expect(llm.send(:messages).last[:content].first[:text]).to eq('Hi!')
    end

    it 'preserves a tool-call exchange through round-trip' do
      response = BedrockAi::Response.new(
        text: '72°F in NYC.',
        messages: [
          { role: 'user', content: [{ text: 'Weather?' }] },
          {
            role: 'assistant',
            content: [{ tool_use: { tool_use_id: 'tu_1', name: 'weather', input: { city: 'NYC' } } }]
          },
          {
            role: 'user',
            content: [{ tool_result: { tool_use_id: 'tu_1', content: [{ text: '72F' }],
                                       status: 'success' } }]
          },
          { role: 'assistant', content: [{ text: '72°F in NYC.' }] }
        ]
      )

      llm.add_response(response)
      expect(llm.send(:messages).size).to eq(4)

      tool_use = llm.send(:messages)[1][:content].first[:tool_use]
      expect(tool_use[:name]).to eq('weather')
      expect(tool_use[:input][:city]).to eq('NYC')
    end
  end

  describe 'full DB workflow' do
    it 'supports load-from-db, query, persist cycle' do
      # Step 1: Load two previous exchanges from DB
      llm.add_response(simple_exchange)
      llm.add_response(tool_exchange)
      expect(llm.send(:messages).size).to eq(6)

      # Step 2: Simulate a new query — manually build what query() would do
      new_response = BedrockAi::Response.new
      new_response.add_message({ role: 'user', content: [{ text: 'Tell me more' }] })
      new_response.add_message({ role: 'assistant', content: [{ text: 'London is great.' }] })
      llm.add_response(new_response)

      expect(llm.send(:messages).size).to eq(8)

      # Step 3: On next page load, restore all 3 exchanges
      new_llm = BedrockAi.new(model: 'anthropic.claude4.5')
      new_llm.add_response(simple_exchange)
      new_llm.add_response(tool_exchange)
      new_llm.add_response(new_response)
      expect(new_llm.send(:messages).size).to eq(8)

      # Verify the full history is intact and usable
      expect(new_llm.send(:messages).first[:content].first[:text]).to eq('Hello')
      expect(new_llm.send(:messages).last[:content].first[:text]).to eq('London is great.')
    end
  end
end
