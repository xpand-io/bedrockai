#!/usr/bin/env ruby
# frozen_string_literal: true

# Manual test script for BedrockAi with two tools backed by free public APIs.
#
# Prerequisites:
#   - AWS credentials configured (e.g. via AWS_PROFILE, AWS_ACCESS_KEY_ID, etc.)
#   - `bundle install` has been run
#
# Usage:
#   bundle exec ruby examples/two_tools.rb

require 'bundler/setup'
require 'bedrockai'
require 'net/http'
require 'json'
require 'uri'

# ---------------------------------------------------------------------------
# Tool 1: Current weather via Open-Meteo (no API key required)
# https://open-meteo.com/en/docs
# ---------------------------------------------------------------------------
class GetWeather < BedrockAi::Tool
  description 'Get the current weather for a location given its latitude and longitude'

  params do
    number :latitude,  description: 'Latitude of the location (-90 to 90)'
    number :longitude, description: 'Longitude of the location (-180 to 180)'
  end

  def execute(latitude:, longitude:)
    uri = URI('https://api.open-meteo.com/v1/forecast')
    uri.query = URI.encode_www_form(
      latitude: latitude,
      longitude: longitude,
      current: 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code',
      temperature_unit: 'celsius',
      wind_speed_unit: 'kmh'
    )

    response = Net::HTTP.get_response(uri)
    data = JSON.parse(response.body)

    current = data['current']
    {
      temperature_celsius: current['temperature_2m'],
      humidity_percent: current['relative_humidity_2m'],
      wind_speed_kmh: current['wind_speed_10m'],
      weather_code: current['weather_code']
    }
  end
end

# ---------------------------------------------------------------------------
# Tool 2: Country information via RestCountries (no API key required)
# https://restcountries.com/
# ---------------------------------------------------------------------------
class GetCountryInfo < BedrockAi::Tool
  description 'Look up information about a country by name (capital, population, languages, coordinates)'

  params do
    string :country_name, description: 'Name of the country to look up (e.g. "France", "Japan")'
  end

  def execute(country_name:)
    uri = URI("https://restcountries.com/v3.1/name/#{URI.encode_uri_component(country_name)}")
    uri.query = URI.encode_www_form(fields: 'name,capital,population,languages,latlng')

    response = Net::HTTP.get_response(uri)
    countries = JSON.parse(response.body)

    return { error: "No country found matching '#{country_name}'" } unless countries.is_a?(Array) && !countries.empty?

    c = countries.first
    {
      name: c.dig('name', 'common'),
      official_name: c.dig('name', 'official'),
      capital: c['capital']&.first,
      population: c['population'],
      languages: c['languages']&.values,
      latitude: c['latlng']&.first,
      longitude: c['latlng']&.last
    }
  end
end

# ---------------------------------------------------------------------------
# Run the query
# ---------------------------------------------------------------------------
MODEL = ENV.fetch('BEDROCK_MODEL', 'us.anthropic.claude-sonnet-4-20250514-v1:0')

puts "Model: #{MODEL}"
puts '-' * 60

llm = BedrockAi
      .new(model: MODEL)
      .set_system_prompt('You are a helpful assistant. Use the available tools to answer questions accurately.')
      .set_temperature(0.3)
      .add_tool(GetWeather.new)
      .add_tool(GetCountryInfo.new)

prompt = "What's the current weather in the capital of Japan? " \
         'First look up Japan to find its capital and coordinates, then get the weather there.'

puts "Prompt: #{prompt}"
puts '-' * 60

response = llm.query(prompt) do |chunk|
  case chunk.type
  when :text
    print chunk.content
  when :tool_use_start
    puts "\n[tool call: #{chunk.tool_name}]"
  when :tool_use_end
    puts '[tool call complete]'
  when :message_stop
    puts "\n[stop reason: #{chunk.stop_reason}]"
  when :metadata
    puts "[tokens — in: #{chunk.input_tokens}, out: #{chunk.output_tokens}]"
  end
end

puts
puts '-' * 60
puts "Total tokens: #{response.total_tokens} (in: #{response.input_tokens}, out: #{response.output_tokens})"

# Extract tool calls from messages (assistant tool_use blocks paired with user tool_result blocks)
tool_uses = response.messages
                    .select { |m| m[:role] == 'assistant' }
                    .flat_map { |m| m[:content].filter_map { |c| c[:tool_use] } }

tool_results = response.messages
                       .select { |m| m[:role] == 'user' }
                       .flat_map { |m| m[:content].filter_map { |c| c[:tool_result] } }

puts "Tool calls: #{tool_uses.size}"
tool_uses.each do |tu|
  tr = tool_results.find { |r| r[:tool_use_id] == tu[:tool_use_id] }
  puts "  - #{tu[:name]}(#{tu[:input]}) => #{tr&.dig(:status) || 'unknown'}"
end
