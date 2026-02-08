# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BedrockAi::Response do
  let(:response) { described_class.new }

  describe '#initialize' do
    it 'starts with empty defaults when no args given' do
      expect(response.text).to eq('')
      expect(response.input_tokens).to eq(0)
      expect(response.output_tokens).to eq(0)
      expect(response.messages).to eq([])
    end

    it 'accepts initial text' do
      r = described_class.new(text: 'Hello')
      expect(r.text).to eq('Hello')
    end

    it 'accepts initial token counts' do
      r = described_class.new(input_tokens: 100, output_tokens: 50)
      expect(r.input_tokens).to eq(100)
      expect(r.output_tokens).to eq(50)
      expect(r.total_tokens).to eq(150)
    end

    it 'accepts initial messages' do
      msgs = [{ role: 'user', content: [{ text: 'Hi' }] }]
      r = described_class.new(messages: msgs)
      expect(r.messages).to eq(msgs)
    end

    it 'accepts all keyword args together' do
      msgs = [{ role: 'user', content: [{ text: 'Hi' }] }]
      r = described_class.new(text: 'Hello', input_tokens: 10, output_tokens: 5, messages: msgs)
      expect(r.text).to eq('Hello')
      expect(r.input_tokens).to eq(10)
      expect(r.output_tokens).to eq(5)
      expect(r.messages.size).to eq(1)
    end

    it 'creates a mutable text string' do
      r = described_class.new(text: 'Hello')
      r.set_text('Hello world')
      expect(r.text).to eq('Hello world')
    end

    it 'handles nil text gracefully' do
      r = described_class.new(text: nil)
      expect(r.text).to eq('')
    end
  end

  describe '#set_text' do
    it 'replaces the response text' do
      response.set_text('Hello')
      response.set_text('Goodbye')
      expect(response.text).to eq('Goodbye')
    end

    it 'handles nil gracefully' do
      response.set_text('Hello')
      response.set_text(nil)
      expect(response.text).to eq('')
    end
  end

  describe '#add_message' do
    it 'records a message' do
      msg = { role: 'user', content: [{ text: 'Hello' }] }
      response.add_message(msg)
      expect(response.messages.size).to eq(1)
      expect(response.messages.first).to eq(msg)
    end

    it 'accumulates messages in order' do
      response.add_message({ role: 'user', content: [{ text: 'Q' }] })
      response.add_message({ role: 'assistant', content: [{ text: 'A' }] })
      expect(response.messages.size).to eq(2)
      expect(response.messages.first[:role]).to eq('user')
      expect(response.messages.last[:role]).to eq('assistant')
    end
  end

  describe '#add_usage' do
    it 'accumulates token counts across multiple calls' do
      response.add_usage(input_tokens: 100, output_tokens: 50)
      response.add_usage(input_tokens: 200, output_tokens: 75)

      expect(response.input_tokens).to eq(300)
      expect(response.output_tokens).to eq(125)
    end

    it 'handles nil values gracefully' do
      response.add_usage(input_tokens: nil, output_tokens: nil)
      expect(response.input_tokens).to eq(0)
      expect(response.output_tokens).to eq(0)
    end

    it 'handles nil usage hash gracefully' do
      response.add_usage(nil)
      expect(response.input_tokens).to eq(0)
      expect(response.output_tokens).to eq(0)
    end
  end

  describe '#total_tokens' do
    it 'returns the sum of input and output tokens' do
      response.add_usage(input_tokens: 100, output_tokens: 50)
      expect(response.total_tokens).to eq(150)
    end
  end

  describe '#to_s' do
    it 'returns the response text' do
      response.set_text('Hello world')
      expect(response.to_s).to eq('Hello world')
    end

    it 'works with string interpolation' do
      response.set_text('test')
      expect("Response: #{response}").to eq('Response: test')
    end
  end

  describe '#inspect' do
    it 'returns a readable summary' do
      response.set_text('Hello world')
      response.add_usage(input_tokens: 100, output_tokens: 50)
      response.add_message({ role: 'user', content: [{ text: 'Hi' }] })

      output = response.inspect
      expect(output).to include('11 chars')
      expect(output).to include('messages=1')
      expect(output).to include('100in/50out')
    end
  end
end
