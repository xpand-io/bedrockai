# frozen_string_literal: true

require_relative 'lib/bedrockai/version'

Gem::Specification.new do |spec|
  spec.name          = 'bedrockai'
  spec.version       = BedrockAi::VERSION
  spec.authors       = ['Kieran']
  spec.summary       = 'A Ruby client for AWS Bedrock with streaming, tool use, and concurrent execution'
  spec.description   = "Provides a clean interface to AWS Bedrock's converse streaming API " \
                       'with support for tool calling (parallel via concurrent-ruby), ' \
                       'streaming responses, and schema-based tool definitions via ruby_llm-schema.'
  spec.homepage      = 'https://github.com/xpand-io/bedrockai'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.files         = Dir['lib/**/*.rb', 'LICENSE.txt', 'README.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'aws-sdk-bedrockruntime', '~> 1.0'
  spec.add_dependency 'concurrent-ruby',        '~> 1.2'
  spec.add_dependency 'ruby_llm-schema',        '~> 0.3'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
