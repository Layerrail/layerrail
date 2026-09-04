# frozen_string_literal: true

RSpec.describe Clover, "azure foundry inference" do
  let(:app) { described_class.allocate }
  let(:response) { Rack::Response.new }
  let(:api_key) { Object.new }
  let(:model_config) { Option::AI_MODELS.find { it["model_name"] == "gpt-6-astra" } }
  let(:model) { CloudflareInferenceModel.new(model_config) }
  let(:client) do
    AzureFoundryClient.new(endpoint: "https://example.services.ai.azure.com", api_key: "test-key", api_version: "2025-01-01-preview")
  end

  before do
    allow(Config).to receive_messages(ai_inference_provider: "azure_foundry", premium_ai_rate_limit_fallback_enabled: false)
    allow(app).to receive(:response).and_return(response)
    allow(app).to receive(:record_inference_tokens)
    allow(AzureFoundryClient).to receive(:new).and_return(client)
  end

  def infer(path, payload, selected_model = model)
    app.handle_azure_foundry_ai_request(path, "Text Generation", api_key, selected_model, payload)
  end

  it "exposes Astra once in the Azure catalog and OpenAI model list" do
    entries = app.catalog_inference_models.select { it.model_name == "gpt-6-astra" }
    expect(entries.length).to eq(1)
    expect(entries.first.tags).to include("display_name" => "GPT-6 Astra", "context_length" => "1.05M")
    expect(app.openai_model_entry(entries.first)).to include("id" => "gpt-6-astra", "owned_by" => "azure_foundry")
  end

  it "does not expose Astra for a Cloudflare-only configuration" do
    allow(Config).to receive(:ai_inference_provider).and_return("cloudflare")

    expect(app.catalog_inference_models.map(&:model_name)).not_to include("gpt-6-astra")
  end

  it "preserves the existing default model" do
    expect(app.catalog_inference_models.first.model_name).to eq("gpt-5")
  end

  it "has active billing rates matching the displayed prices" do
    now = Time.utc(2026, 9, 4, 12)
    {"input" => model.prompt_billing_resource, "output" => model.completion_billing_resource}.each do |kind, resource|
      rate = BillingRate.from_resource_properties("InferenceTokens", resource, "global", false, now)
      expect(rate).to include("billed_by" => "amount")
      expect(rate["unit_price"] * 1_000_000).to be_within(0.00001).of(model.tags["pricing"][kind])
    end
    expect(BillingRate.rates.map { it["id"] }.uniq.length).to eq(BillingRate.rates.length)
  end

  it "handles playground chat parameters, keeps images, and meters actual tokens" do
    messages = [{"role" => "user", "content" => [
      {"type" => "text", "text" => "Describe this"},
      {"type" => "image_url", "image_url" => {"url" => "https://example.com/image.png"}},
    ]}]
    body = {"model" => "gpt-6-astra", "choices" => [{"message" => {"content" => "A test image"}}], "usage" => {"prompt_tokens" => 12, "completion_tokens" => 34}}
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/chat/completions")
      .with(body: {"model" => "gpt-6-astra", "messages" => messages, "max_completion_tokens" => 128, "reasoning_effort" => "low"})
      .to_return(status: 200, body: body.to_json)

    expect(infer("chat/completions", {"model" => "gpt-6-astra", "messages" => messages, "max_tokens" => 128, "temperature" => 1.0, "top_p" => 1.0, "reasoning_effort" => "low", "stream" => false})).to eq(body)
    expect(upstream).to have_been_requested.once
    expect(response.status).to eq(200)
    expect(response["X-LayerRail-AI-Model"]).to eq("gpt-6-astra")
    expect(app).to have_received(:record_inference_tokens).with(api_key, model, "input", "azure-gpt-6-astra-input", 12)
    expect(app).to have_received(:record_inference_tokens).with(api_key, model, "output", "azure-gpt-6-astra-output", 34)
  end

  it "keeps explicit completion limits when the Azure deployment has a custom name" do
    custom_model = CloudflareInferenceModel.new(model_config.merge("tags" => model_config["tags"].merge("deployment" => "production-astra")))
    payload = {"max_tokens" => 64, "max_completion_tokens" => 256, "temperature" => 0.7, "top_p" => 0.9, "logprobs" => true}

    app.normalize_azure_foundry_payload!(payload, custom_model)

    expect(payload).to eq("max_completion_tokens" => 256, "logprobs" => true)
  end

  it "does not convert token limits for unrelated reasoning models" do
    other_model = CloudflareInferenceModel.new("model_name" => "DeepSeek-R1", "provider" => "azure_foundry", "tags" => {"reasoning" => true})
    payload = {"max_tokens" => 64}

    app.normalize_azure_foundry_payload!(payload, other_model)

    expect(payload).to eq("max_tokens" => 64)
  end

  it "forwards native Responses tool calls, reasoning, and schemas without loss" do
    payload = {
      "model" => "gpt-6-astra",
      "input" => [{"type" => "function_call_output", "call_id" => "call-1", "output" => ""}],
      "previous_response_id" => "resp-previous",
      "tools" => [{"type" => "function", "name" => "get_status", "strict" => true, "parameters" => {"type" => "object", "properties" => {}, "required" => [], "additionalProperties" => false}}],
      "reasoning" => {"effort" => "max", "summary" => "auto"},
      "max_output_tokens" => 2048,
      "store" => false,
    }
    body = {
      "id" => "resp-1", "object" => "response", "status" => "completed", "model" => "gpt-6-astra",
      "output" => [{"type" => "function_call", "call_id" => "call-2", "name" => "get_status", "arguments" => "{}"}],
      "usage" => {"input_tokens" => 4, "output_tokens" => 9, "output_tokens_details" => {"reasoning_tokens" => 5}},
    }
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      .with(body: payload)
      .to_return(status: 200, body: body.to_json)

    expect(infer("responses", payload)).to eq(body)
    expect(upstream).to have_been_requested.once
    expect(response["X-LayerRail-AI-Model"]).to eq("gpt-6-astra")
    expect(app).to have_received(:record_inference_tokens).with(api_key, model, "input", "azure-gpt-6-astra-input", 4)
    expect(app).to have_received(:record_inference_tokens).with(api_key, model, "output", "azure-gpt-6-astra-output", 9)
  end

  it "maps token aliases and deployment names for native Responses" do
    custom_model = CloudflareInferenceModel.new(model_config.merge("tags" => model_config["tags"].merge("deployment" => "production-astra")))
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      .with(body: {"model" => "production-astra", "input" => "Hello", "max_output_tokens" => 100})
      .to_return(status: 200, body: {"usage" => {"input_tokens" => 2, "output_tokens" => 3}}.to_json)

    infer("responses", {"model" => "gpt-6-astra", "input" => "Hello", "max_output_tokens" => 100, "max_tokens" => 20, "max_completion_tokens" => 40, "temperature" => 0.5, "top_p" => 0.9}, custom_model)

    expect(upstream).to have_been_requested.once
  end

  it "does not invent a Responses token limit when none was requested" do
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
      .with(body: {"model" => "gpt-6-astra", "input" => "Hello"})
      .to_return(status: 200, body: {"usage" => {"input_tokens" => 2, "output_tokens" => 3}}.to_json)

    infer("responses", {"input" => "Hello"})

    expect(upstream).to have_been_requested.once
  end

  [400, 401, 403, 404, 429, 500].each do |status|
    it "preserves native Responses HTTP #{status} without billing or switching models" do
      body = {"error" => {"code" => "UpstreamError", "message" => "Request failed"}}
      stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
        .to_return(status:, body: body.to_json)

      expect(infer("responses", {"input" => "Hello"})).to eq(body)
      expect(response.status).to eq(status)
      expect(app).not_to have_received(:record_inference_tokens)
    end
  end

  %w[chat/completions responses].product(%w[stream background]).each do |path, parameter|
    it "rejects unsupported #{parameter} requests on #{path} before calling Azure" do
      expect(client).not_to receive(:openai_request)
      expect {
        infer(path, {"messages" => [], "input" => "Hello", parameter => true})
      }.to raise_error(CloverError, /synchronous requests/) { expect(it.code).to eq(400) }
    end
  end

  it "rejects malformed chat messages" do
    expect { infer("chat/completions", {"messages" => "Hello"}) }.to raise_error(CloverError, /messages must be an array/)
  end

  it "keeps older Azure models on their existing Chat Completions endpoint" do
    legacy_model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == "gpt-5" })
    upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/deployments/gpt-5/chat/completions?api-version=2025-01-01-preview")
      .with(body: {"model" => "gpt-5", "messages" => [{"role" => "user", "content" => "Hello"}], "max_completion_tokens" => 100})
      .to_return(status: 200, body: {"usage" => {"prompt_tokens" => 2, "completion_tokens" => 3}}.to_json)

    infer("chat/completions", {"messages" => [{"role" => "user", "content" => "Hello"}], "max_tokens" => 100}, legacy_model)

    expect(upstream).to have_been_requested.once
  end
end
