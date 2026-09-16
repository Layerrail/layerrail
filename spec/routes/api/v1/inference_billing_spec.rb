# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "paid inference API" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("paid-inference") }
  let(:api_key) { ApiKey.create_inference_api_key(project) }

  before do
    allow(Config).to receive_messages(
      ai_inference_enabled: true, ai_inference_provider: "cloudflare,azure_foundry",
      azure_foundry_endpoint: "https://example.services.ai.azure.com",
      azure_foundry_api_key: "test-provider-key",
      premium_ai_rate_limit_fallback_enabled: false,
    )
    allow(BachsClient).to receive(:enabled?).and_return(true)
    header "Authorization", "Bearer #{api_key.key}"
    header "Content-Type", "application/json"
  end

  def connect_billing
    billing_info = BillingInfo.create(stripe_id: "bachs:#{project.ubid}")
    project.update(billing_info_id: billing_info.id)
    PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment-#{project.ubid}")
  end

  it "rejects Azure calls without payment before contacting the provider" do
    allow(Config).to receive(:premium_ai_metering_enabled).and_return(false)
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
    post "/v1/responses", {model: "gpt-6-astra", input: "Hello"}.to_json
    expect(last_response.status).to eq(402)
    expect(upstream).not_to have_been_requested
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "rejects unpriced Cloudflare calls even after billing is connected" do
    connect_billing
    post "/v1/run", {model: "@cf/meta/llama-3.2-3b-instruct", prompt: "Hello"}.to_json
    expect(last_response.status).to eq(503)
    expect(JSON.parse(last_response.body).to_s).to include("pricing is configured")
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "records Azure input and output from the provider response, not request fields" do
    connect_billing
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      .to_return(status: 200, body: {id: "response-1", output_text: "Hello", usage: {input_tokens: 5, output_tokens: 11}}.to_json)
    post "/v1/responses", {model: "gpt-6-astra", input: "Hello", usage: {input_tokens: 0, output_tokens: 0}}.to_json
    expect(last_response.status).to eq(200)
    expect(upstream).to have_been_requested.once
    records = BillingRecord.where(project_id: project.id).all
    expect(records.to_h { [it.resource_tags["token_kind"], it.amount] }).to eq("input" => 5, "output" => 11)
    expect(records.map { it.resource_tags.to_h }).to all(include("paid_inference" => true))
  end

  it "does not charge fabricated counts when Azure omits usage" do
    connect_billing
    stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      .to_return(status: 200, body: {id: "response-1", output_text: "Hello"}.to_json)
    post "/v1/responses", {model: "gpt-6-astra", input: "Hello"}.to_json
    expect(last_response.status).to eq(502)
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end
end
