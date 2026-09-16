# frozen_string_literal: true

RSpec.describe Clover, "cloudflare run" do
  let(:inference_app) { described_class.allocate }
  let(:model) do
    CloudflareInferenceModel.new(
      "id" => "cf-openai-gpt-oss-120b", "model_name" => "@cf/openai/gpt-oss-120b",
      "tags" => {"api" => "run", "capability" => "Text Generation"},
    )
  end

  it "sends agent instructions and retrieved context to native GPT OSS as one system message" do
    agent = instance_double(AiAgent, system_prompt: "Answer using our support policy.")
    document = instance_double(AiKnowledgeDocument, title: "Support policy")
    chunk = instance_double(AiKnowledgeChunk, document:, content: "Support is available Monday to Friday.")
    history = [
      {"role" => "user", "content" => "When is support available?"},
      {"role" => "assistant", "content" => "Monday to Friday."},
      {"role" => "user", "content" => "Is Saturday included?"},
    ]
    system = "Answer using our support policy.\n\n" \
      "Use this project knowledge when it is relevant. Do not invent details that are not supported by the context.\n\n" \
      "Source 1: Support policy\nSupport is available Monday to Friday."
    payload = inference_app.ai_agent_cloudflare_payload(agent, model, history, [chunk], {"max_tokens" => 128})
    provider = instance_double(CloudflareWorkersAiClient)
    expect(provider).to receive(:run_request).with(model.model_name, {
      "messages" => [{"role" => "system", "content" => system}, *history],
      "stream" => false, "max_tokens" => 128,
    }).and_return([200, {"result" => {"response" => "No."}}])

    # Agent construction and provider dispatch both normalize the payload.
    # The second pass must not add the system message again.
    inference_app.cloudflare_run_request(provider, model, payload)
    expect(history.map { it["role"] }).to eq(%w[user assistant user])
  end

  it "does not duplicate an existing native system message" do
    payload = {
      "system" => "Be helpful.",
      "messages" => [{"role" => "system", "content" => "Be helpful."}, {"role" => "user", "content" => "Hello"}],
    }
    normalized = inference_app.cloudflare_run_text_payload(model, payload)
    expect(normalized).to eq("messages" => payload["messages"])
    expect(inference_app.cloudflare_run_text_payload(model, normalized)).to eq(normalized)
    expect(payload["system"]).to eq("Be helpful.")
  end

  it "also translates top-level system text for native Hugging Face models" do
    native = CloudflareInferenceModel.new("id" => "native-test", "model_name" => "@hf/example/model")
    payload = {"system" => "Be brief.", "messages" => [{"role" => "user", "content" => "Hello"}]}
    expect(inference_app.cloudflare_run_text_payload(native, payload)).to eq(
      "messages" => [{"role" => "system", "content" => "Be brief."}, {"role" => "user", "content" => "Hello"}],
    )
  end

  it "leaves third-party run payloads and existing native message instructions unchanged" do
    third_party = CloudflareInferenceModel.new("id" => "third-party-test", "model_name" => "example/model")
    payload = {"system" => "Be brief.", "messages" => [{"role" => "user", "content" => "Hello"}]}
    expect(inference_app.cloudflare_run_text_payload(third_party, payload)).to equal(payload)
    native = {"messages" => [{"role" => "system", "content" => "Be brief."}, {"role" => "user", "content" => "Hello"}]}
    expect(inference_app.cloudflare_run_text_payload(model, native)).to equal(native)
  end
end
