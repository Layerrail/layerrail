# frozen_string_literal: true

RSpec.describe Clover, "inference billing" do
  let(:app) { described_class.allocate }
  let(:project) { Project.create(name: "inference-meter") }
  let(:api_key) { ApiKey.create_inference_api_key(project) }
  let(:model) do
    CloudflareInferenceModel.new(
      "model_name" => "gpt-5", "provider" => "azure_foundry",
      "prompt_billing_resource" => "azure-gpt-5-input",
      "completion_billing_resource" => "azure-gpt-5-output",
      "tags" => {"capability" => "Text Generation"},
    )
  end

  it "persists provider usage and ignores client-provided usage" do
    app.record_cloudflare_inference_usage(
      api_key, model,
      {"usage" => {"prompt_tokens" => 12, "completion_tokens" => 8}},
      {"messages" => [], "usage" => {"prompt_tokens" => 0, "completion_tokens" => 0}},
    )
    records = BillingRecord.where(project_id: project.id).all.to_h { [it.resource_tags["token_kind"], it] }
    expect(records.fetch("input").amount).to eq(12)
    expect(records.fetch("output").amount).to eq(8)
    expect(records.values.map { it.resource_tags.to_h }).to all(include("paid_inference" => true))
    expect(records["input"].resource_tags["unit_price"]).to eq(records["input"].billing_rate["unit_price"].to_s)
  end

  it "preserves explicit zero usage instead of charging estimated tokens" do
    expect {
      app.record_cloudflare_inference_usage(
        api_key, model, {"usage" => {"input_tokens" => 0, "output_tokens" => 0}, "output_text" => "not billed"},
        {"input" => "a long input"},
      )
    }.not_to change(BillingRecord, :count)
  end

  it "does not invent token charges when the provider omits usage" do
    expect {
      app.record_cloudflare_inference_usage(api_key, model, {"output_text" => "an answer"}, {"input" => "an input"})
    }.to raise_error(CloverError, /did not report token usage/) { expect(it.code).to eq(502) }
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "keeps historical trial records separate and increments only new paid usage" do
    now = Time.now.utc
    midnight = Time.utc(now.year, now.month, now.day)
    rate = BillingRate.from_resource_properties("InferenceTokens", model.prompt_billing_resource, "global")
    historical = BillingRecord.create(
      project_id: project.id, resource_id: api_key.id, resource_name: "historic trial",
      billing_rate_id: rate["id"], span: Sequel.pg_range(midnight...(midnight + 86_400)),
      amount: 400, resource_tags: {premium_ai_trial: true},
    )
    app.record_inference_tokens(api_key, model, "input", model.prompt_billing_resource, 20)
    app.record_inference_tokens(api_key, model, "input", model.prompt_billing_resource, 10)
    expect(historical.reload.amount).to eq(400)
    paid = BillingRecord.where(project_id: project.id).with_tag("paid_inference", true).all
    expect(paid.length).to eq(1)
    expect(paid.first.amount).to eq(30)
  end

  it "does not record positive usage against a zero-priced resource" do
    expect {
      app.record_inference_tokens(api_key, model, "input", "preview-input", 10)
    }.to raise_error(CloverError, /pricing is configured/)
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "buffers provider SSE data across arbitrary byte boundaries and preserves usage" do
    source = "data: #{JSON.generate({"choices" => [{"delta" => {"content" => "café"}}]})}\r\n\r\n" \
      "data: #{JSON.generate({"usage" => {"prompt_tokens" => 123, "completion_tokens" => 45}})}\n\n" \
      "data: [DONE]\n\n"
    buffer = +"".b
    events = source.b.bytes.flat_map do |byte|
      buffer << byte
      app.cloudflare_stream_events(buffer)
    end
    expect(events.first.dig("choices", 0, "delta", "content")).to eq("café")
    expect(events.last["usage"]).to eq("prompt_tokens" => 123, "completion_tokens" => 45)
    expect(buffer).to be_empty
  end

  it "reads a final complete SSE event without requiring a trailing separator" do
    buffer = +'data: {"usage":{"input_tokens":0,"output_tokens":0}}'
    expect(app.cloudflare_stream_events(buffer)).to be_empty
    expect(app.cloudflare_stream_events(buffer, final: true)).to eq([{"usage" => {"input_tokens" => 0, "output_tokens" => 0}}])
    expect(buffer).to be_empty
  end

  it "records final provider usage before a client can disconnect from the response" do
    response = Clover::RodaResponse.new
    request = instance_double(Clover::RodaRequest)
    client = instance_double(CloudflareWorkersAiClient)
    allow(app).to receive_messages(response:, request:)
    allow(CloudflareWorkersAiClient).to receive(:new).and_return(client)
    payload = {"stream" => true, "stream_options" => {"include_usage" => false}}
    content = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
    usage = "data: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":8}}\n\n"
    provider_finished = false
    allow(client).to receive(:openai_stream_request) do |_path, forwarded, &emit|
      expect(forwarded["stream_options"]).to include("include_usage" => true)
      emit.call(content)
      emit.call(usage[0...13])
      emit.call(usage[13..])
      provider_finished = true
    end
    expect(request).to receive(:halt) do |status, headers, body|
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(provider_finished).to be(true)
      records = BillingRecord.where(project_id: project.id).all
      expect(records.to_h { [it.resource_tags["token_kind"], it.amount] }).to eq("input" => 12, "output" => 8)
      expect(body.join).to eq(content + usage)
      # A consumer stopping after its first chunk cannot interrupt provider reads.
      body.each { break }
    end

    app.stream_cloudflare_ai_request(api_key, model, payload)
  end

  it "withholds streamed output if the provider omits final token usage" do
    request = instance_double(Clover::RodaRequest)
    client = instance_double(CloudflareWorkersAiClient)
    allow(app).to receive(:request).and_return(request)
    allow(CloudflareWorkersAiClient).to receive(:new).and_return(client)
    allow(client).to receive(:openai_stream_request).and_yield("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n")
    expect(request).not_to receive(:halt)

    expect {
      app.stream_cloudflare_ai_request(api_key, model, {"stream" => true})
    }.to raise_error(CloverError, /did not report token usage/)
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end
end
