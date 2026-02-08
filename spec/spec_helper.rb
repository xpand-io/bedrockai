# frozen_string_literal: true

require 'bedrockai'

RSpec.configure do |config|
  config.formatter = :documentation

  # Prevent real AWS client instantiation in all specs.
  config.before do
    allow(Aws::BedrockRuntime::Client).to receive(:new)
      .and_return(instance_double(Aws::BedrockRuntime::Client))
    allow(Logger).to receive(:new).and_return(instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil))
  end
end
