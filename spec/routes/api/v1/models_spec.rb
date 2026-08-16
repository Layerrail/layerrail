# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "GET /v1/models" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:api_key) { ApiKey.create_inference_api_key(project) }

  before do
    allow(Config).to receive(:ai_inference_enabled).and_return(true)
    allow(Config).to receive(:ai_inference_provider).and_return("cloudflare")
  end

  it "returns an OpenAI-compatible model list for a valid inference API key" do
    header "Authorization", "Bearer #{api_key.key}"
    get "/v1/models"

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["object"]).to eq("list")
    expect(body["data"]).to be_an(Array)
    expect(body["data"]).not_to be_empty

    entry = body["data"].find { it["id"] == "gpt-5.6-sol" }
    expect(entry).to include(
      "id" => "gpt-5.6-sol",
      "object" => "model",
      "owned_by" => "azure_foundry",
    )
    expect(entry["created"]).to be_a(Integer)
  end

  it "rejects requests without an inference API key" do
    get "/v1/models"

    expect(last_response).to have_api_error(401, "invalid inference API key provided in Authorization header")
  end

  it "rejects invalid inference API keys" do
    header "Authorization", "Bearer invalid-key"
    get "/v1/models"

    expect(last_response).to have_api_error(401, "invalid inference API key provided in Authorization header")
  end

  it "rejects personal access tokens" do
    pat = ApiKey.create_personal_access_token(user, project:)
    header "Authorization", "Bearer pat-#{pat.ubid}-#{pat.key}"
    get "/v1/models"

    expect(last_response).to have_api_error(401, "invalid inference API key provided in Authorization header")
  end

  it "returns not enabled when inference is disabled" do
    allow(Config).to receive(:ai_inference_enabled).and_return(false)
    header "Authorization", "Bearer #{api_key.key}"
    get "/v1/models"

    expect(last_response).to have_api_error(501, "AI Inference is not enabled.")
  end
end
