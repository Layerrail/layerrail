# frozen_string_literal: true

require "excon"
require "base64"
require "json"

class CloudflareWorkersAiClient
  def initialize(account_id: Config.cloudflare_account_id, api_token: Config.cloudflare_api_token)
    fail CloverError.new(500, "MissingConfiguration", "CLOUDFLARE_ACCOUNT_ID is required for Cloudflare Workers AI.") unless account_id
    fail CloverError.new(500, "MissingConfiguration", "CLOUDFLARE_API_TOKEN is required for Cloudflare Workers AI.") unless api_token

    @account_id = account_id
    @connection = Excon.new(
      "https://api.cloudflare.com",
      headers: {
        "Authorization" => "Bearer #{api_token}",
        "Content-Type" => "application/json",
      },
    )
  end

  def openai_request(path, payload)
    response = @connection.post(
      path: "/client/v4/accounts/#{@account_id}/ai/v1/#{path}",
      body: payload.to_json,
      expects: [200, 400, 401, 403, 404, 429, 500, 502, 503],
    )

    [response.status, JSON.parse(response.body)]
  end

  def run_request(model_name, payload)
    response = @connection.post(
      path: "/client/v4/accounts/#{@account_id}/ai/run/#{model_name}",
      body: payload.to_json,
      expects: [200, 400, 401, 403, 404, 429, 500, 502, 503],
    )

    [response.status, parse_response_body(response)]
  end

  private

  def parse_response_body(response)
    JSON.parse(response.body)
  rescue JSON::ParserError
    {
      "result" => Base64.strict_encode64(response.body),
      "content_type" => response.headers["Content-Type"],
    }
  end
end
