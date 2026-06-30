# frozen_string_literal: true

RSpec.describe PremiumAIUsageMeter do
  let(:project) { Project.create(name: "premium-ai") }
  let(:api_key) { ApiKey.create_inference_api_key(project) }
  let(:model) do
    CloudflareInferenceModel.new(
      "id" => "premium-test",
      "model_name" => "premium-test",
      "provider" => "azure_foundry",
      "prompt_billing_resource" => "azure-gpt-5-input",
      "completion_billing_resource" => "azure-gpt-5-output",
      "tags" => {"capability" => "Text Generation", "pricing" => {"input" => 1.75, "output" => 14.0}}
    )
  end

  before do
    allow(Config).to receive(:premium_ai_metering_enabled).and_return(true)
    allow(Config).to receive(:premium_ai_polar_event_name).and_return("layerrail_ai_usage")
    allow(Config).to receive(:premium_ai_charge_threshold_cents).and_return(500)
    allow(Config).to receive(:premium_ai_monthly_spend_cap_cents).and_return(1000)
  end

  it "requires billing for premium models" do
    expect {
      described_class.record(api_key:, model:, token_kind: "input", resource_family: "azure-gpt-5-input", tokens: 1000, billing_rate: nil)
    }.to raise_error(CloverError, /Premium AI models require billing/)
  end

  it "ingests premium usage into Polar when billing is connected" do
    project.update(billing_info_id: BillingInfo.create(stripe_id: "polar:#{project.ubid}").id)

    expect(PolarClient).to receive(:enabled?).and_return(true)
    expect(PolarClient).to receive(:ingest_events).with([
      hash_including(
        name: "layerrail_ai_usage",
        external_customer_id: project.ubid,
        metadata: hash_including(
          project_id: project.ubid,
          api_key_id: api_key.ubid,
          model: "premium-test",
          provider: "azure_foundry",
          token_kind: "input",
          resource_family: "azure-gpt-5-input",
          tokens: 1000
        )
      )
    ])

    described_class.record(api_key:, model:, token_kind: "input", resource_family: "azure-gpt-5-input", tokens: 1000, billing_rate: nil)
  end
end
