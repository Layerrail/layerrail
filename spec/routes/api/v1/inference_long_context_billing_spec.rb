# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "GPT-6 long-context billing" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("long-context-inference") }
  let(:api_key) { ApiKey.create_inference_api_key(project) }
  let(:model) { CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == "gpt-6.1-sol" }) }

  before do
    allow(Config).to receive_messages(
      ai_inference_enabled: true, ai_inference_provider: "azure_foundry",
      azure_foundry_endpoint: "https://example.services.ai.azure.com", azure_foundry_api_key: "test-provider-key",
      premium_ai_rate_limit_fallback_enabled: false,
    )
    allow(BachsClient).to receive(:enabled?).and_return(true)
    billing_info = BillingInfo.create(stripe_id: "bachs:#{project.ubid}")
    project.update(billing_info_id: billing_info.id)
    PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment-#{project.ubid}")
    header "Authorization", "Bearer #{api_key.key}"
    header "Content-Type", "application/json"
  end

  input_token_counts = [272_000, 272_001].freeze
  %w[responses chat/completions].each do |path|
    input_token_counts.each do |input_tokens|
      it "bills the full #{path} request at the correct tier for #{input_tokens} provider input tokens" do
        usage = if path == "responses"
          {input_tokens:, output_tokens: 7, input_tokens_details: {cached_tokens: 100_000}}
        else
          {prompt_tokens: input_tokens, completion_tokens: 7, prompt_tokens_details: {cached_tokens: 100_000}}
        end
        upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/#{path}")
          .to_return(status: 200, body: {model: "gpt-6.1-sol", output: [], usage:}.to_json)
        payload = (path == "responses") ? {input: "Short request"} : {messages: [{role: "user", content: "Short request"}]}
        # A caller-supplied usage object must never select its own billing tier.
        post "/v1/#{path}", payload.merge(model: "gpt-6.1-sol", usage: {input_tokens: 1}).to_json

        expect(last_response.status).to eq(200)
        expect(upstream).to have_been_requested.once
        records = BillingRecord.where(project_id: project.id).all
        expect(records.to_h { [it.resource_tags["token_kind"], it.amount] }).to eq("input" => input_tokens, "output" => 7)
        long_context = input_tokens > 272_000
        expected_prices = long_context ? {"input" => BigDecimal("0.0000028"), "output" => BigDecimal("0.0000105")} :
          {"input" => BigDecimal("0.0000014"), "output" => BigDecimal("0.000007")}
        expect(records.to_h { [it.resource_tags["token_kind"], BigDecimal(it.resource_tags["unit_price"])] }).to eq(expected_prices)
        expect(records.map { BillingRate.from_id(it.billing_rate_id).fetch("resource_family") })
          .to match_array(long_context ? [model.long_context_prompt_billing_resource, model.long_context_completion_billing_resource] :
            [model.prompt_billing_resource, model.completion_billing_resource])
      end
    end
  end

  %i[long_context_prompt_billing_resource long_context_completion_billing_resource].each do |reader|
    it "rejects a missing #{reader} rate before even a short Azure request" do
      allow_any_instance_of(CloudflareInferenceModel).to receive(reader).and_return("missing-long-context-rate")
      upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      post "/v1/responses", {model: "gpt-6.1-sol", input: "Hello"}.to_json

      expect(last_response.status).to eq(503)
      expect(last_response.body).to include("pricing is configured")
      expect(upstream).not_to have_been_requested
      expect(BillingRecord.where(project_id: project.id)).to be_empty
    end
  end

  it "uses Astra's discounted base tariff above the new models' threshold" do
    stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      .to_return(status: 200, body: {model: "gpt-6-astra", usage: {input_tokens: 272_001, output_tokens: 7}}.to_json)
    post "/v1/responses", {model: "gpt-6-astra", input: "Hello"}.to_json

    expect(last_response.status).to eq(200)
    records = BillingRecord.where(project_id: project.id).all
    expect(records.to_h { [it.resource_tags["token_kind"], BigDecimal(it.resource_tags["unit_price"])] })
      .to eq("input" => BigDecimal("0.000005"), "output" => BigDecimal("0.000025"))
  end

  %w[gpt-6.1-sol gpt-6-sol gpt-6-luna].each do |name|
    it "shows every #{name} billing tier in the catalog and uses matching active rates" do
      family_model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == name })
      serialized = Serializers::InferenceEndpoint.serialize(family_model)
      expect(serialized[:tags]).to include("long_context_threshold" => 272_000)
      expect(serialized[:catalog_prices]).to include(include("label" => "Input >272K (per 1M tokens)"),
        include("label" => "Output >272K input (per 1M tokens)"))
      expect(BillingRate.million_token_price(family_model.long_context_prompt_billing_resource))
        .to eq(family_model.tags.dig("pricing", "long_context", "input"))
      expect(BillingRate.million_token_price(family_model.long_context_completion_billing_resource))
        .to eq(family_model.tags.dig("pricing", "long_context", "output"))
    end
  end

  it "blocks malformed long-context configuration before allowing inference" do
    [nil, 0, "272000"].each do |threshold|
      model.tags["long_context_threshold"] = threshold
      expect(PremiumAiUsageMeter.billable_model?(model)).to be(false)
    end
  end
end
