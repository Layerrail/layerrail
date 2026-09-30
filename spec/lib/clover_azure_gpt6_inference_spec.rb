# frozen_string_literal: true

RSpec.describe Clover, "azure gpt6 inference" do
  let(:app) { described_class.allocate }
  let(:response) { Rack::Response.new }
  let(:api_key) { Object.new }
  let(:client) { AzureFoundryClient.new(endpoint: "https://example.services.ai.azure.com", api_key: "test-key") }
  let(:configurations) { YAML.load_file("config/ai_models.yml") }

  before do
    allow(Config).to receive_messages(ai_inference_provider: "azure_foundry", premium_ai_rate_limit_fallback_enabled: false)
    allow(app).to receive(:response).and_return(response)
    allow(app).to receive(:record_inference_tokens)
    allow(AzureFoundryClient).to receive(:new).and_return(client)
  end

  def family_model(name, deployment: name)
    config = configurations.find { it["model_name"] == name }
    expect(config).not_to be_nil
    CloudflareInferenceModel.new(config.merge("tags" => config.fetch("tags").merge("deployment" => deployment)))
  end

  def infer(model, path, payload)
    app.handle_azure_foundry_ai_request(path, "Text Generation", api_key, model, payload)
  end

  %w[gpt-6.1-sol gpt-6-sol gpt-6-luna].each do |name|
    it "configures #{name} once with active rates matching its catalog prices" do
      model = family_model(name)
      expect(configurations.count { it["model_name"] == name }).to eq(1)
      expect(model.tags).to include("native_responses" => true, "context_length" => "1.05M")
      {"input" => model.prompt_billing_resource, "output" => model.completion_billing_resource}.each do |kind, resource|
        rate = BillingRate.from_resource_properties("InferenceTokens", resource, "global", false, Time.utc(2026, 10, 1))
        expect(rate).not_to be_nil
        expect(rate["unit_price"] * 1_000_000).to be_within(0.00001).of(model.tags.fetch("pricing").fetch(kind))
      end
    end

    it "routes #{name} chat by its custom deployment, strips unsupported sampling, and bills returned tokens" do
      model = family_model(name, deployment: "production-model")
      body = {"model" => name, "choices" => [{"message" => {"content" => "OK"}}], "usage" => {"prompt_tokens" => 12, "completion_tokens" => 34}}
      upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/chat/completions")
        .with(body: {"model" => "production-model", "messages" => [{"role" => "user", "content" => "Hello"}], "max_completion_tokens" => 128, "reasoning_effort" => "low"})
        .to_return(status: 200, body: body.to_json)

      expect(infer(model, "chat/completions", {"messages" => [{"role" => "user", "content" => "Hello"}], "max_tokens" => 128,
        "reasoning_effort" => "low", "temperature" => 0.7, "top_p" => 0.9, "top_logprobs" => 3, "logprobs" => true})).to eq(body)
      expect(upstream).to have_been_requested.once
      expect(response["X-LayerRail-AI-Model"]).to eq(name)
      expect(app).to have_received(:record_inference_tokens).with(api_key, model, "input", model.prompt_billing_resource, 12)
      expect(app).to have_received(:record_inference_tokens).with(api_key, model, "output", model.completion_billing_resource, 34)
    end

    it "preserves #{name} Responses tools and images while removing only unsupported logprobs includes" do
      model = family_model(name)
      input = [{"role" => "user", "content" => [{"type" => "input_image", "image_url" => "https://example.com/image.png"}]}]
      tools = [{"type" => "function", "name" => "get_status", "parameters" => {"type" => "object", "properties" => {}, "additionalProperties" => false}}]
      payload = {"input" => input, "tools" => tools, "reasoning" => {"effort" => "high"}, "include" => ["reasoning.encrypted_content", "message.output_text.logprobs"],
                 "temperature" => 0.7, "top_p" => 0.9, "top_logprobs" => 3, "max_tokens" => 128, "store" => false}
      body = {"model" => name, "usage" => {"input_tokens" => 8, "output_tokens" => 5}}
      upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
        .with(body: {"model" => name, "input" => input, "tools" => tools, "reasoning" => {"effort" => "high"},
                     "include" => ["reasoning.encrypted_content"], "max_output_tokens" => 128, "store" => false})
        .to_return(status: 200, body: body.to_json)

      expect(infer(model, "responses", payload)).to eq(body)
      expect(upstream).to have_been_requested.once
      expect(app).to have_received(:record_inference_tokens).with(api_key, model, "input", model.prompt_billing_resource, 8)
      expect(app).to have_received(:record_inference_tokens).with(api_key, model, "output", model.completion_billing_resource, 5)
    end

    it "rejects unsupported minimal reasoning for #{name} before calling Azure or billing" do
      expect(client).not_to receive(:openai_request)
      expect { infer(family_model(name), "responses", {"input" => "Hello", "reasoning" => {"effort" => "minimal"}}) }
        .to raise_error(CloverError, /reasoning effort/) { expect(it.code).to eq(400) }
      expect(app).not_to have_received(:record_inference_tokens)
    end
  end

  %w[gpt-6-astra gpt-6.1-sol gpt-6-sol gpt-6-luna].each do |name|
    it "directs #{name} max reasoning chat requests to Responses before calling Azure or billing" do
      expect(client).not_to receive(:openai_request)
      expect { infer(family_model(name), "chat/completions", {"messages" => [], "reasoning_effort" => "max"}) }
        .to raise_error(CloverError, /max reasoning.*\/v1\/responses/) { expect(it.code).to eq(400) }
      expect(app).not_to have_received(:record_inference_tokens)
    end

    it "preserves #{name} max reasoning in native Responses requests" do
      payload = {"input" => "Hello", "reasoning" => {"effort" => "max"}}
      upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
        .with(body: payload.merge("model" => name))
        .to_return(status: 200, body: {"usage" => {"input_tokens" => 1, "output_tokens" => 2}}.to_json)

      infer(family_model(name), "responses", payload)
      expect(upstream).to have_been_requested.once
    end
  end

  %w[gpt-6-astra gpt-6.1-sol].product(%w[chat/completions responses]).each do |name, path|
    it "rejects none reasoning for #{name} on #{path}" do
      model = family_model(name)
      payload = (path == "responses") ? {"input" => "Hello", "reasoning" => {"effort" => "none"}} : {"messages" => [], "reasoning_effort" => "none"}
      expect(client).not_to receive(:openai_request)
      expect { infer(model, path, payload) }.to raise_error(CloverError, /reasoning effort/) { expect(it.code).to eq(400) }
    end
  end

  %w[gpt-6-astra gpt-6.1-sol].each do |name|
    it "directs #{name} chat tool calls to Responses before calling Azure or billing" do
      expect(client).not_to receive(:openai_request)
      expect { infer(family_model(name), "chat/completions", {"messages" => [], "tools" => [{"type" => "function", "function" => {"name" => "get_status"}}]}) }
        .to raise_error(CloverError, /tool calling requires \/v1\/responses/) { expect(it.code).to eq(400) }
      expect(app).not_to have_received(:record_inference_tokens)
    end

    it "allows #{name} chat with an explicitly empty tool list and no tool selection" do
      payload = {"messages" => [], "tools" => [], "tool_choice" => "none"}
      upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/chat/completions")
        .with(body: payload.merge("model" => name))
        .to_return(status: 200, body: {"usage" => {"prompt_tokens" => 1, "completion_tokens" => 2}}.to_json)

      infer(family_model(name), "chat/completions", payload)
      expect(upstream).to have_been_requested.once
    end
  end

  ["low", false, []].each do |malformed_reasoning|
    it "rejects malformed Responses reasoning #{malformed_reasoning.inspect} before contacting Azure" do
      expect(client).not_to receive(:openai_request)
      expect { infer(family_model("gpt-6.1-sol"), "responses", {"input" => "Hello", "reasoning" => malformed_reasoning}) }
        .to raise_error(CloverError, /reasoning must be an object/) { expect(it.code).to eq(400) }
    end
  end

  %w[gpt-6-sol gpt-6-luna].each do |name|
    it "preserves #{name} sampling and chat function tools with none reasoning" do
      model = family_model(name)
      payload = {"messages" => [], "reasoning_effort" => "none", "temperature" => 0.7, "top_p" => 0.9, "top_logprobs" => 3, "logprobs" => true,
                 "tools" => [{"type" => "function", "function" => {"name" => "get_status"}}]}
      upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/chat/completions")
        .with(body: payload.merge("model" => name))
        .to_return(status: 200, body: {"usage" => {"prompt_tokens" => 1, "completion_tokens" => 2}}.to_json)

      infer(model, "chat/completions", payload)
      expect(upstream).to have_been_requested.once
    end

    it "rejects #{name} chat functions without explicit none reasoning" do
      expect(client).not_to receive(:openai_request)
      expect { infer(family_model(name), "chat/completions", {"messages" => [], "tools" => [{"type" => "function", "function" => {"name" => "get_status"}}]}) }
        .to raise_error(CloverError, /reasoning_effort.*none.*\/v1\/responses/) { expect(it.code).to eq(400) }
    end
  end
end
