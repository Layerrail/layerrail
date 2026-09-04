# frozen_string_literal: true

require "excon"
require "json"
require "securerandom"

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
    @anthropic_connection = Excon.new(
      azure_foundry_base_url(endpoint),
      headers: {
        "x-api-key" => api_key,
        "Content-Type" => "application/json",
        "anthropic-version" => "2023-06-01",
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

  def openai_request(path, payload)
    response = @connection.post(
      path: "/openai/v1/#{path}",
      query: {},
      body: payload.to_json,
      read_timeout: 300,
      expects: EXPECTED_STATUSES,
    )

    [response.status, parse_response_body(response)]
  end

  def anthropic_messages(deployment, payload)
    response = @anthropic_connection.post(
      path: "/anthropic/v1/messages",
      body: anthropic_payload(deployment, payload).to_json,
      expects: EXPECTED_STATUSES,
    )

    [response.status, openai_compatible_anthropic_response(parse_response_body(response), deployment)]
  end

  private

  def azure_foundry_base_url(endpoint)
    base = endpoint.chomp("/")
    base = base.sub(%r{/api/projects/.*\z}, "")
    base = base.sub(%r{/openai(?:/v1)?\z}, "")
    base = base.sub(".openai.azure.com", ".services.ai.azure.com")
    base.sub(%r{/anthropic\z}, "")
  end

  def anthropic_payload(deployment, payload)
    messages = []
    system_messages = []

    payload.fetch("messages", []).each do |message|
      role = message["role"].to_s
      if role == "system"
        system_messages << anthropic_content_text(message["content"])
        next
      end

      messages << {
        "role" => role == "assistant" ? "assistant" : "user",
        "content" => anthropic_content(message["content"]),
      }
    end

    {
      "model" => deployment,
      "messages" => messages,
      "system" => system_messages.join("\n\n"),
      "max_tokens" => payload["max_tokens"] || payload["max_completion_tokens"] || 1024,
      "temperature" => payload["temperature"],
      "stop_sequences" => payload["stop"],
    }.compact
  end

  def anthropic_content(content)
    return content if content.is_a?(Array)

    anthropic_content_text(content)
  end

  def anthropic_content_text(content)
    case content
    when Array
      content.filter_map { it["text"] || it["content"] }.join("\n")
    else
      content.to_s
    end
  end

  def openai_compatible_anthropic_response(body, deployment)
    return body if body["error"]

    text = body.fetch("content", []).filter_map { it["text"] }.join
    usage = body["usage"] || {}
    completion_id = body["id"].to_s.strip
    completion_id = "chatcmpl-#{SecureRandom.hex(16)}" if completion_id.empty?

    {
      "id" => completion_id,
      "object" => "chat.completion",
      "created" => Time.now.to_i,
      "model" => body["model"] || deployment,
      "choices" => [
        {
          "index" => 0,
          "message" => {"role" => "assistant", "content" => text},
          "finish_reason" => body["stop_reason"] || "stop",
        },
      ],
      "usage" => {
        "prompt_tokens" => usage["input_tokens"].to_i,
        "completion_tokens" => usage["output_tokens"].to_i,
        "total_tokens" => usage["input_tokens"].to_i + usage["output_tokens"].to_i,
      },
    }
  end

  def parse_response_body(response)
    JSON.parse(response.body)
  rescue JSON::ParserError
    {"error" => {"message" => response.body.to_s}}
  end
end
