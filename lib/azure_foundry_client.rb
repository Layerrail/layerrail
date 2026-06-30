# frozen_string_literal: true

require "excon"
require "json"

class AzureFoundryClient
  EXPECTED_STATUSES = [200, 400, 401, 402, 403, 404, 408, 409, 429, 500, 502, 503].freeze

  def initialize(endpoint: Config.azure_foundry_endpoint, api_key: Config.azure_foundry_api_key, api_version: Config.azure_foundry_api_version)
    fail CloverError.new(500, "MissingConfiguration", "AZURE_FOUNDRY_ENDPOINT is required for Azure AI Foundry.") unless endpoint
    fail CloverError.new(500, "MissingConfiguration", "AZURE_FOUNDRY_API_KEY is required for Azure AI Foundry.") unless api_key

    @api_version = api_version
    @connection = Excon.new(
      endpoint.chomp("/"),
      headers: {
        "api-key" => api_key,
        "Content-Type" => "application/json",
      },
    )
  end

  def chat_completion(deployment, payload)
    response = @connection.post(
      path: "/openai/deployments/#{deployment}/chat/completions",
      query: { "api-version" => @api_version },
      body: payload.to_json,
      expects: EXPECTED_STATUSES,
    )

    [response.status, parse_response_body(response)]
  end

  def chat_completion_stream(deployment, payload, &)
    @connection.post(
      path: "/openai/deployments/#{deployment}/chat/completions",
      query: { "api-version" => @api_version },
      body: payload.to_json,
      expects: EXPECTED_STATUSES,
      response_block: proc { |chunk, _remaining, _total| yield chunk },
    )
  end

  private

  def parse_response_body(response)
    JSON.parse(response.body)
  rescue JSON::ParserError
    {"error" => {"message" => response.body.to_s}}
  end
end
