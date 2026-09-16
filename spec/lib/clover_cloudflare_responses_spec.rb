# frozen_string_literal: true

RSpec.describe Clover, "cloudflare responses" do
  let(:inference_app) { described_class.allocate }

  it "extracts only final assistant output text for agents and response text" do
    response = {
      "output" => [
        {"type" => "reasoning", "content" => [{"type" => "reasoning_text", "text" => "Hidden reasoning"}]},
        {"type" => "message", "role" => "assistant", "channel" => "analysis", "content" => [{"type" => "output_text", "text" => "Hidden analysis"}]},
        {"type" => "message", "role" => "assistant", "channel" => "final",
         "content" => [{"type" => "output_text", "text" => "Final answer"},
           {"type" => "output_text", "channel" => "analysis", "text" => "Hidden part analysis"},
           {"type" => "output_text", "channel" => "reasoning", "text" => "Hidden part reasoning"},
           {"type" => "output_text", "channel" => "final", "text" => "More detail"}]},
        {"type" => "message", "role" => "assistant", "content" => [{"type" => "output_text", "text" => "Last part"}]},
      ],
    }
    [response, {"result" => response}].each do |body|
      expect(inference_app.ai_agent_response_text(body)).to eq("Final answer\nMore detail\nLast part")
      expect(inference_app.cloudflare_response_text(body)).to eq("Final answer\nMore detail\nLast part")
    end
  end

  it "does not turn reasoning-only output or a generic output_text shortcut into an answer" do
    response = {
      "output_text" => "Hidden reasoning copied into a shortcut",
      "output" => [
        {"type" => "reasoning", "content" => [{"type" => "reasoning_text", "text" => "Hidden reasoning"}]},
        {"type" => "message", "role" => "assistant", "channel" => "analysis",
         "content" => [{"type" => "output_text", "text" => "Hidden analysis"}]},
      ],
    }
    expect(inference_app.ai_agent_response_text(response)).to eq("")
    expect(inference_app.cloudflare_response_text(response)).to eq("")
  end

  it "preserves a plain output_text response when no structured output is present" do
    expect(inference_app.ai_agent_response_text({"output_text" => "OK"})).to eq("OK")
    expect(inference_app.cloudflare_response_text({"output_text" => "OK"})).to eq("OK")
  end

  it "normalizes the playground text parts Cloudflare rejects at body.input and preserves assistant history" do
    payload = {
      "model" => "@cf/openai/gpt-oss-120b",
      "instructions" => "Answer briefly.",
      "input" => [
        {"role" => "user", "content" => [{"type" => "text", "text" => "First question"}]},
        {"role" => "assistant", "content" => [{"type" => "text", "text" => "Previous answer"}]},
        {"role" => "user", "content" => [{"type" => "text", "text" => "Follow-up"}, {"type" => "text", "text" => "More context"}]},
      ],
      "temperature" => 1,
      "top_p" => 1,
      "stream" => false,
    }

    inference_app.normalize_cloudflare_payload!(payload, "responses")

    expect(payload).to eq(
      "model" => "@cf/openai/gpt-oss-120b", "instructions" => "Answer briefly.",
      "input" => [
        {"role" => "user", "content" => "First question"},
        {"role" => "assistant", "content" => "Previous answer"},
        {"role" => "user", "content" => "Follow-up\nMore context"},
      ],
      "temperature" => 1, "top_p" => 1, "stream" => false, "max_output_tokens" => 1024,
    )
  end

  it "preserves existing Responses messages, reasoning, tool calls, and tool outputs" do
    input = [
      {"role" => "developer", "content" => "Be helpful."},
      {"role" => "user", "content" => [{"type" => "input_text", "text" => "Describe this"}, {"type" => "input_image", "image_url" => "https://example.com/image.png"}]},
      {"type" => "reasoning", "id" => "rs_previous", "summary" => []},
      {"type" => "message", "id" => "msg_previous", "role" => "assistant", "status" => "completed",
       "content" => [{"type" => "output_text", "text" => "Checking.", "annotations" => []}]},
      {"type" => "function_call", "id" => "fc_previous", "call_id" => "call_previous", "name" => "lookup", "arguments" => "{}"},
      {"type" => "function_call_output", "call_id" => "call_previous", "output" => ""},
    ]
    original_input = Marshal.load(Marshal.dump(input))
    payload = {"input" => input, "max_output_tokens" => 64}

    inference_app.normalize_cloudflare_payload!(payload, "responses")

    expect(payload["input"]).to eq(original_input)
    expect(payload["max_output_tokens"]).to eq(64)
  end

  it "continues to accept plain input strings" do
    payload = {"input" => "Hello", "max_tokens" => 8}
    inference_app.normalize_cloudflare_payload!(payload, "responses")
    expect(payload).to eq("input" => "Hello", "max_output_tokens" => 8, "stream" => false)
  end

  it "continues to translate legacy messages and system instructions" do
    payload = {
      "instructions" => "Be brief.",
      "messages" => [
        {"role" => "system", "content" => "Be helpful."},
        {"role" => "user", "content" => [{"type" => "text", "text" => "Hello"}]},
        {"role" => "assistant", "content" => "Hi"},
      ],
    }
    inference_app.normalize_cloudflare_payload!(payload, "responses")
    expect(payload).to eq(
      "instructions" => "Be brief.\n\nBe helpful.",
      "input" => [{"role" => "user", "content" => "Hello"}, {"role" => "assistant", "content" => "Hi"}],
      "max_output_tokens" => 1024, "stream" => false,
    )
  end

  describe "provider dispatch" do
    let(:model) do
      CloudflareInferenceModel.new(
        "id" => "cloudflare-gpt-oss-20b", "model_name" => "@cf/openai/gpt-oss-20b",
        "tags" => {"api" => "responses", "capability" => "Text Generation"},
      )
    end
    let(:api_key) { instance_double(ApiKey, project: instance_double(Project, active?: true)) }
    let(:payload) do
      {
        "model" => model.model_name,
        "input" => [{"role" => "user", "content" => [{"type" => "text", "text" => "Hello"}]}],
        "tools" => [{"type" => "function", "name" => "lookup", "parameters" => {
          "type" => "object", "properties" => {}, "required" => [], "additionalProperties" => false,
        }}],
        "text" => {"format" => {"type" => "json_schema", "name" => "result", "schema" => {
          "type" => "object", "properties" => {}, "required" => [], "additionalProperties" => false,
        }}},
      }
    end

    before do
      allow(Config).to receive(:ai_inference_enabled).and_return(true)
      allow(inference_app).to receive_messages(
        before_authenticated_hash_branches: nil, no_authorization_needed: nil, no_audit_log: nil,
        catalog_inference_provider?: true, inference_api_key_from_authorization_header: api_key,
        parse_inference_payload: payload, catalog_inference_models: [model],
      )
      allow(inference_app).to receive(:validate_premium_ai_access!).with(api_key, model)
    end

    it "forwards normalized input while preserving empty JSON-schema fields" do
      original_tools = Marshal.load(Marshal.dump(payload["tools"]))
      original_text = Marshal.load(Marshal.dump(payload["text"]))
      body = {"output_text" => "Hi", "usage" => {"input_tokens" => 5, "output_tokens" => 1}}
      provider = instance_double(CloudflareWorkersAiClient)
      allow(CloudflareWorkersAiClient).to receive(:new).and_return(provider)
      allow(inference_app).to receive(:response).and_return(double(:status= => nil))
      expect(provider).to receive(:openai_request).with("responses", {
        "model" => model.model_name,
        "input" => [{"role" => "user", "content" => "Hello"}],
        "tools" => original_tools, "text" => original_text, "max_output_tokens" => 1024, "stream" => false,
      }).and_return([200, body])
      expect(inference_app).to receive(:record_cloudflare_inference_usage).with(api_key, model, body, payload)

      expect(inference_app.handle_cloudflare_ai_request("responses", "Text Generation")).to eq(body)
    end

    context "with an Azure model" do
      let(:model) do
        CloudflareInferenceModel.new(
          "id" => "azure-gpt-5", "model_name" => "gpt-5", "provider" => "azure_foundry",
          "tags" => {"native_responses" => true, "capability" => "Text Generation"},
        )
      end

      it "delegates the untouched payload to the existing Azure handler" do
        original_payload = Marshal.load(Marshal.dump(payload))
        expect(inference_app).not_to receive(:normalize_cloudflare_payload!)
        expect(CloudflareWorkersAiClient).not_to receive(:new)
        expect(inference_app).to receive(:handle_azure_foundry_ai_request).with("responses", "Text Generation", api_key, model, original_payload).and_return("azure-response")

        expect(inference_app.handle_cloudflare_ai_request("responses", "Text Generation")).to eq("azure-response")
        expect(payload).to eq(original_payload)
      end
    end
  end
end
