# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BedrockAi::Tool do
  let(:tool_class) do
    Class.new(described_class) do
      description 'Find users by name'

      params do
        string :query, description: 'Search query'
      end

      def execute(query:)
        { users: [{ name: query }] }
      end
    end
  end

  let(:tool) { tool_class.new }

  describe '#name' do
    it 'derives name from class name' do
      stub_const('FindUsers', tool_class)
      expect(FindUsers.new.name).to eq('find_users')
    end

    it 'falls back to anonymous_tool for anonymous classes' do
      expect(tool.name).to eq('anonymous_tool')
    end
  end

  describe '#description' do
    it 'uses description from the class' do
      expect(tool.description).to eq('Find users by name')
    end

    it 'falls back to a default when not set' do
      bare_class = Class.new(described_class) do
        def execute(**); end
      end

      expect(bare_class.new.description).to start_with('Tool: ')
    end
  end

  describe '#to_bedrock_tool_spec' do
    it 'returns a valid Bedrock tool_spec hash' do
      stub_const('FindUsers', tool_class)
      t = FindUsers.new
      spec = t.to_bedrock_tool_spec
      expect(spec).to have_key(:tool_spec)
      expect(spec[:tool_spec][:name]).to eq('find_users')
      expect(spec[:tool_spec][:description]).to eq('Find users by name')
      expect(spec[:tool_spec][:input_schema]).to have_key(:json)
    end

    it 'returns a minimal schema when no params defined' do
      bare_class = Class.new(described_class) do
        def execute(**); end
      end

      spec = bare_class.new.to_bedrock_tool_spec
      json = spec[:tool_spec][:input_schema][:json]
      expect(json).to eq({ 'type' => 'object', 'properties' => {} })
    end

    it 'stringifies all schema keys and values' do
      spec = tool.to_bedrock_tool_spec
      json = spec[:tool_spec][:input_schema][:json]
      expect(json.keys).to all(be_a(String))
    end
  end

  describe '#execute' do
    it 'delegates to the subclass implementation' do
      result = tool.execute(query: 'Alice')
      expect(result).to eq({ users: [{ name: 'Alice' }] })
    end

    it 'raises NotImplementedError when not overridden' do
      bare_class = Class.new(described_class)
      expect { bare_class.new.execute(foo: 'bar') }.to raise_error(NotImplementedError)
    end
  end

  describe '.params' do
    it 'supports string params' do
      klass = Class.new(described_class) do
        params { string :name, description: 'User name' }
        def execute(**); end
      end

      spec = klass.new.to_bedrock_tool_spec
      props = spec[:tool_spec][:input_schema][:json]['properties']
      expect(props).to have_key('name')
      expect(props['name']['type']).to eq('string')
    end

    it 'supports number params' do
      klass = Class.new(described_class) do
        params do
          number :latitude, description: 'Lat'
          number :longitude, description: 'Lng'
        end
        def execute(**); end
      end

      spec = klass.new.to_bedrock_tool_spec
      props = spec[:tool_spec][:input_schema][:json]['properties']
      expect(props).to have_key('latitude')
      expect(props).to have_key('longitude')
    end
  end
end
