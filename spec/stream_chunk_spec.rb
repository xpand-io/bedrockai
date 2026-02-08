# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BedrockAi::StreamChunk do
  describe '#text?' do
    it 'returns true for text chunks' do
      chunk = described_class.new(type: :text, content: 'hello')
      expect(chunk.text?).to be true
    end

    it 'returns false for non-text chunks' do
      chunk = described_class.new(type: :tool_use_start)
      expect(chunk.text?).to be false
    end
  end

  describe '#reasoning?' do
    it 'returns true for reasoning chunks' do
      chunk = described_class.new(type: :reasoning, content: 'Let me think...')
      expect(chunk.reasoning?).to be true
    end

    it 'returns false for text chunks' do
      chunk = described_class.new(type: :text, content: 'hello')
      expect(chunk.reasoning?).to be false
    end
  end

  describe '#reasoning_signature?' do
    it 'returns true for reasoning_signature chunks' do
      chunk = described_class.new(type: :reasoning_signature, signature: 'abc123')
      expect(chunk.reasoning_signature?).to be true
    end
  end

  describe '#tool_use_start?' do
    it 'returns true for tool_use_start chunks' do
      chunk = described_class.new(
        type: :tool_use_start,
        tool_use_id: 'id_1',
        tool_name: 'search'
      )
      expect(chunk.tool_use_start?).to be true
      expect(chunk.tool_use_id).to eq('id_1')
      expect(chunk.tool_name).to eq('search')
    end
  end

  describe '#tool_use_delta?' do
    it 'returns true for tool_use_delta chunks' do
      chunk = described_class.new(type: :tool_use_delta, content: '{"q":')
      expect(chunk.tool_use_delta?).to be true
    end
  end

  describe '#tool_use_end?' do
    it 'returns true for tool_use_end chunks' do
      chunk = described_class.new(type: :tool_use_end, content_block_index: 1)
      expect(chunk.tool_use_end?).to be true
    end

    it 'returns false for non-tool_use_end chunks' do
      chunk = described_class.new(type: :text)
      expect(chunk.tool_use_end?).to be false
    end
  end

  describe '#message_start?' do
    it 'returns true for message_start chunks' do
      chunk = described_class.new(type: :message_start)
      expect(chunk.message_start?).to be true
    end

    it 'returns false for non-message_start chunks' do
      chunk = described_class.new(type: :text)
      expect(chunk.message_start?).to be false
    end
  end

  describe '#message_stop?' do
    it 'returns true for message_stop chunks' do
      chunk = described_class.new(type: :message_stop, stop_reason: 'end_turn')
      expect(chunk.message_stop?).to be true
    end
  end

  describe '#tool_use_stop?' do
    it 'returns true when stop_reason is tool_use' do
      chunk = described_class.new(type: :message_stop, stop_reason: 'tool_use')
      expect(chunk.tool_use_stop?).to be true
    end

    it 'returns false for other stop reasons' do
      chunk = described_class.new(type: :message_stop, stop_reason: 'end_turn')
      expect(chunk.tool_use_stop?).to be false
    end
  end

  describe '#metadata?' do
    it 'returns true for metadata chunks' do
      chunk = described_class.new(type: :metadata)
      expect(chunk.metadata?).to be true
    end

    it 'returns false for non-metadata chunks' do
      chunk = described_class.new(type: :text)
      expect(chunk.metadata?).to be false
    end
  end

  describe '#content_block_stop?' do
    it 'returns true for content_block_stop chunks' do
      chunk = described_class.new(type: :content_block_stop, content_block_index: 0)
      expect(chunk.content_block_stop?).to be true
    end

    it 'returns false for non-content_block_stop chunks' do
      chunk = described_class.new(type: :text)
      expect(chunk.content_block_stop?).to be false
    end
  end

  describe 'token tracking' do
    it 'exposes input_tokens and output_tokens on metadata chunks' do
      chunk = described_class.new(
        type: :metadata,
        input_tokens: 150,
        output_tokens: 75
      )
      expect(chunk.input_tokens).to eq(150)
      expect(chunk.output_tokens).to eq(75)
    end

    it 'defaults token counts to nil on non-metadata chunks' do
      chunk = described_class.new(type: :text, content: 'hello')
      expect(chunk.input_tokens).to be_nil
      expect(chunk.output_tokens).to be_nil
    end
  end

  describe 'other attributes' do
    it 'exposes content_block_index' do
      chunk = described_class.new(type: :text, content: 'hi', content_block_index: 3)
      expect(chunk.content_block_index).to eq(3)
    end

    it 'exposes usage hash on metadata chunks' do
      usage = { input_tokens: 100, output_tokens: 50 }
      chunk = described_class.new(type: :metadata, usage: usage, input_tokens: 100, output_tokens: 50)
      expect(chunk.usage).to eq(usage)
    end

    it 'exposes signature on reasoning_signature chunks' do
      chunk = described_class.new(type: :reasoning_signature, signature: 'sig_abc')
      expect(chunk.signature).to eq('sig_abc')
    end
  end
end
