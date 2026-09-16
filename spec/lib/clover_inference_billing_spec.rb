# frozen_string_literal: true

RSpec.describe Clover, "inference billing" do
  let(:inference_app) { described_class.allocate }
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

  let(:cached_model) do
    CloudflareInferenceModel.new(
      "model_name" => "@cf/cached-test", "provider" => "cloudflare",
      "prompt_billing_resource" => "azure-gpt-5-input",
      "cached_prompt_billing_resource" => "azure-gpt-4o-mini-input",
      "completion_billing_resource" => "azure-gpt-5-output",
      "tags" => {"capability" => "Text Generation"},
    )
  end

  it "persists provider usage and ignores client-provided usage" do
    inference_app.record_cloudflare_inference_usage(
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
      inference_app.record_cloudflare_inference_usage(
        api_key, model, {"usage" => {"input_tokens" => 0, "output_tokens" => 0}, "output_text" => "not billed"},
        {"input" => "a long input"},
      )
    }.not_to change(BillingRecord, :count)
  end

  ["prompt_tokens_details", "input_tokens_details"].each do |details_key|
    it "splits inclusive input using #{details_key} without billing cache hits twice" do
      inference_app.record_cloudflare_inference_usage(api_key, cached_model,
        {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20, details_key => {"cached_tokens" => 75}}}, {})

      records = BillingRecord.where(project_id: project.id).all.to_h { [it.resource_tags["token_kind"], it] }
      expect(records.transform_values(&:amount)).to eq("input" => 25, "cached_input" => 75, "output" => 20)
      expect(records.fetch("cached_input").billing_rate["resource_family"]).to eq(cached_model.cached_prompt_billing_resource)
      expect(records.fetch("input").amount + records.fetch("cached_input").amount).to eq(100)
    end
  end

  it "uses native cached_tokens from the provider result and ignores client-supplied counts" do
    inference_app.record_cloudflare_inference_usage(api_key, cached_model,
      {"result" => {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20, "cached_tokens" => 75}}},
      {"usage" => {"prompt_tokens" => 100, "cached_tokens" => 100}})

    records = BillingRecord.where(project_id: project.id).all.to_h { [it.resource_tags["token_kind"], it.amount] }
    expect(records).to eq("input" => 25, "cached_input" => 75, "output" => 20)
  end

  it "records explicit zero cache hits at the ordinary input price" do
    inference_app.record_cloudflare_inference_usage(api_key, cached_model,
      {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20, "prompt_tokens_details" => {"cached_tokens" => 0}}}, {})
    records = BillingRecord.where(project_id: project.id).all.to_h { [it.resource_tags["token_kind"], it.amount] }
    expect(records).to eq("input" => 100, "output" => 20)
  end

  it "does not create ordinary input usage when the entire prompt is cached" do
    inference_app.record_cloudflare_inference_usage(api_key, cached_model,
      {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20, "cached_tokens" => 100}}, {})
    records = BillingRecord.where(project_id: project.id).all.to_h { [it.resource_tags["token_kind"], it.amount] }
    expect(records).to eq("cached_input" => 100, "output" => 20)
  end

  it "accepts matching cache aliases only once" do
    inference_app.record_cloudflare_inference_usage(api_key, cached_model,
      {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20, "cached_tokens" => 75,
                   "prompt_tokens_details" => {"cached_tokens" => 75}}}, {})
    expect(BillingRecord.where(project_id: project.id).with_tag("token_kind", "cached_input").sum(:amount)).to eq(75)
  end

  it "requires an explicit cache count when the provider contract does not define omission" do
    expect {
      inference_app.record_cloudflare_inference_usage(api_key, cached_model,
        {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20}}, {})
    }.to raise_error(CloverError, /valid cached token usage/) { expect(it.code).to eq(502) }
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "treats an omitted cache count as zero only for a verified cold-cache contract" do
    cached_model.tags["cache_usage_optional"] = true
    inference_app.record_cloudflare_inference_usage(api_key, cached_model,
      {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20}}, {})
    records = BillingRecord.where(project_id: project.id).all.to_h { [it.resource_tags["token_kind"], it.amount] }
    expect(records).to eq("input" => 100, "output" => 20)
  end

  [nil, -1, 101, 1.5, "invalid", false].each do |cached_tokens|
    it "rejects invalid cached usage #{cached_tokens.inspect} before recording any usage" do
      cached_model.tags["cache_usage_optional"] = true
      expect(inference_app).not_to receive(:record_inference_tokens)
      expect {
        inference_app.record_cloudflare_inference_usage(api_key, cached_model,
          {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20,
                       "prompt_tokens_details" => {"cached_tokens" => cached_tokens}}}, {})
      }.to raise_error(CloverError, /valid cached token usage/)
      expect(BillingRecord.where(project_id: project.id)).to be_empty
    end
  end

  it "rejects malformed details, conflicting counters, and separate Anthropic cache totals" do
    cached_model.tags["cache_usage_optional"] = true
    invalid = [
      {"prompt_tokens_details" => nil},
      {"prompt_tokens_details" => []},
      {"cached_tokens" => 5, "prompt_tokens_details" => {"cached_tokens" => 6}},
      {"cache_read_input_tokens" => 10},
      {"cache_creation_input_tokens" => 10},
    ]
    tokens = {"prompt_tokens" => 100, "completion_tokens" => 20}
    invalid.each do |cache_usage|
      expect {
        inference_app.record_cloudflare_inference_usage(api_key, cached_model,
          {"usage" => tokens.merge(cache_usage)}, {})
      }.to raise_error(CloverError, /valid cached token usage/)
    end
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "does not record ordinary usage when the configured cache rate is unavailable" do
    allow(cached_model).to receive(:cached_prompt_billing_resource).and_return("preview-input")
    expect {
      inference_app.record_cloudflare_inference_usage(api_key, cached_model,
        {"usage" => {"prompt_tokens" => 100, "completion_tokens" => 20, "cached_tokens" => 0}}, {})
    }.to raise_error(CloverError, /pricing is configured/)
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end

  it "does not invent token charges when the provider omits usage" do
    expect {
      inference_app.record_cloudflare_inference_usage(api_key, model, {"output_text" => "an answer"}, {"input" => "an input"})
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
    inference_app.record_inference_tokens(api_key, model, "input", model.prompt_billing_resource, 20)
    inference_app.record_inference_tokens(api_key, model, "input", model.prompt_billing_resource, 10)
    expect(historical.reload.amount).to eq(400)
    paid = BillingRecord.where(project_id: project.id).with_tag("paid_inference", true).all
    expect(paid.length).to eq(1)
    expect(paid.first.amount).to eq(30)
  end

  it "does not record positive usage against a zero-priced resource" do
    expect {
      inference_app.record_inference_tokens(api_key, model, "input", "preview-input", 10)
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
      inference_app.cloudflare_stream_events(buffer)
    end
    expect(events.first.dig("choices", 0, "delta", "content")).to eq("café")
    expect(events.last["usage"]).to eq("prompt_tokens" => 123, "completion_tokens" => 45)
    expect(buffer).to be_empty
  end

  it "reads a final complete SSE event without requiring a trailing separator" do
    buffer = +'data: {"usage":{"input_tokens":0,"output_tokens":0}}'
    expect(inference_app.cloudflare_stream_events(buffer)).to be_empty
    expect(inference_app.cloudflare_stream_events(buffer, final: true)).to eq([{"usage" => {"input_tokens" => 0, "output_tokens" => 0}}])
    expect(buffer).to be_empty
  end

  it "records final provider usage before a client can disconnect from the response" do
    response = Clover::RodaResponse.new
    request = instance_double(Clover::RodaRequest)
    client = instance_double(CloudflareWorkersAiClient)
    allow(inference_app).to receive_messages(response:, request:)
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

    inference_app.stream_cloudflare_ai_request(api_key, model, payload)
  end

  it "withholds streamed output if the provider omits final token usage" do
    request = instance_double(Clover::RodaRequest)
    client = instance_double(CloudflareWorkersAiClient)
    allow(inference_app).to receive(:request).and_return(request)
    allow(CloudflareWorkersAiClient).to receive(:new).and_return(client)
    allow(client).to receive(:openai_stream_request).and_yield("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n")
    expect(request).not_to receive(:halt)

    expect {
      inference_app.stream_cloudflare_ai_request(api_key, model, {"stream" => true})
    }.to raise_error(CloverError, /did not report token usage/)
    expect(BillingRecord.where(project_id: project.id)).to be_empty
  end
end
