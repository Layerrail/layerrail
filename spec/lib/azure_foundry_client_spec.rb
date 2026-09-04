# frozen_string_literal: true

RSpec.describe AzureFoundryClient do
  let(:client) do
    described_class.new(
      endpoint: "https://example.services.ai.azure.com",
      api_key: "test-key",
      api_version: "2025-01-01-preview"
    )
  end

  describe "#openai_request" do
    {
      "chat/completions" => {"model" => "gpt-6-astra", "messages" => [{"role" => "user", "content" => "Hello"}]},
      "responses" => {"model" => "gpt-6-astra", "input" => "Hello"},
    }.each do |path, payload|
      it "uses the Azure v1 #{path} endpoint and API key" do
        upstream = stub_request(:post, "https://example.services.ai.azure.com/openai/v1/#{path}")
          .with(headers: {"api-key" => "test-key", "Content-Type" => "application/json"}, body: payload)
          .to_return(status: 200, body: {"id" => "result-1"}.to_json)

        expect(client.openai_request(path, payload)).to eq([200, {"id" => "result-1"}])
        expect(upstream).to have_been_requested.once
      end
    end

    it "accepts an endpoint that already includes the openai v1 base path" do
      v1_client = described_class.new(endpoint: "https://example.openai.azure.com/openai/v1/", api_key: "test-key", api_version: "2025-01-01-preview")
      upstream = stub_request(:post, "https://example.openai.azure.com/openai/v1/responses")
        .to_return(status: 200, body: {"id" => "resp-1"}.to_json)

      expect(v1_client.openai_request("responses", {"model" => "gpt-6-astra", "input" => "Hello"})).to eq([200, {"id" => "resp-1"}])
      expect(upstream).to have_been_requested.once
    end

    it "preserves deployment errors" do
      body = {"error" => {"code" => "DeploymentNotFound", "message" => "Deploy GPT-6 Astra first"}}
      stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
        .to_return(status: 404, body: body.to_json)

      expect(client.openai_request("responses", {"model" => "gpt-6-astra"})).to eq([404, body])
    end

    it "handles non-JSON upstream errors" do
      stub_request(:post, "https://example.services.ai.azure.com/openai/v1/responses")
        .to_return(status: 502, body: "Bad gateway")

      expect(client.openai_request("responses", {})).to eq([502, {"error" => {"message" => "Bad gateway"}}])
    end
  end

  it "preserves id when Anthropic response includes one" do
    result = client.send(:openai_compatible_anthropic_response, {
      "id" => "msg_abc123",
      "model" => "claude-sonnet-5",
      "content" => [{"text" => "ok"}],
      "usage" => {"input_tokens" => 2, "output_tokens" => 3}
    }, "claude-sonnet-5")

    expect(result["id"]).to eq("msg_abc123")
  end

  it "generates an OpenAI-compatible id when Anthropic response omits id" do
    result = client.send(:openai_compatible_anthropic_response, {
      "model" => "claude-sonnet-5",
      "content" => [{"text" => "ok"}],
      "usage" => {"input_tokens" => 2, "output_tokens" => 3}
    }, "claude-sonnet-5")

    expect(result["id"]).to start_with("chatcmpl-")
    expect(result["id"].length).to be > "chatcmpl-".length
  end
end
