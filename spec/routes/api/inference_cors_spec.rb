# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "inference API CORS" do
  let(:console_origin) { Config.base_url.chomp("/") }
  let(:api_env) do
    {
      "HTTP_HOST" => "api.console.layerrail.com",
      "HTTP_ORIGIN" => console_origin,
    }
  end

  before do
    allow(Config).to receive_messages(ai_inference_enabled: true, ai_inference_provider: "cloudflare")
  end

  it "allows the console to preflight authenticated inference requests" do
    options "/v1/chat/completions", {}, api_env.merge(
      "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
      "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "authorization,content-type",
    )

    expect(last_response.status).to eq(204)
    expect(last_response.body).to be_empty
    expect(last_response.headers).to include(
      "access-control-allow-origin" => console_origin,
      "access-control-allow-methods" => include("POST"),
      "access-control-allow-headers" => include("Authorization", "Content-Type"),
      "access-control-max-age" => "86400",
      "vary" => include("Origin"),
    )
  end

  it "includes CORS headers on inference authentication errors" do
    post "/v1/chat/completions", JSON.generate({
      model: "claude-opus-5",
      messages: [{role: "user", content: "ping"}],
    }), api_env.merge(
      "CONTENT_TYPE" => "application/json",
      "HTTP_AUTHORIZATION" => "Bearer invalid-inference-key",
    )

    expect(last_response).to have_api_error(401, "invalid inference API key provided in Authorization header")
    expect(last_response.headers).to include(
      "access-control-allow-origin" => console_origin,
      "access-control-expose-headers" => include("X-LayerRail-AI-Model", "X-LayerRail-AI-Fallback-Model"),
      "vary" => include("Origin"),
    )
  end

  it "does not grant browser access to an untrusted origin" do
    options "/v1/chat/completions", {}, api_env.merge(
      "HTTP_ORIGIN" => "https://malicious.example",
      "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
      "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "authorization,content-type",
    )

    expect(last_response.status).to eq(204)
    expect(last_response.headers).not_to include("access-control-allow-origin")
  end
end
