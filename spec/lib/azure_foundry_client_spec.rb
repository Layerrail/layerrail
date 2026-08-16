# frozen_string_literal: true

RSpec.describe AzureFoundryClient do
  let(:client) do
    described_class.new(
      endpoint: "https://example.services.ai.azure.com",
      api_key: "test-key",
      api_version: "2025-01-01-preview"
    )
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
