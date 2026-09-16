# frozen_string_literal: true

RSpec.describe PremiumAiUsageMeter do
  let(:project) { Project.create(name: "paid-ai") }
  let(:model) do
    CloudflareInferenceModel.new(
      "id" => "paid-test",
      "model_name" => "paid-test",
      "provider" => "azure_foundry",
      "prompt_billing_resource" => "azure-gpt-5-input",
      "completion_billing_resource" => "azure-gpt-5-output",
      "tags" => {"capability" => "Text Generation"},
    )
  end

  before do
    allow(BachsClient).to receive(:enabled?).and_return(true)
  end

  def connect_billing(fraud: false)
    billing_info = BillingInfo.create(stripe_id: "bachs:#{project.ubid}")
    project.update(billing_info_id: billing_info.id)
    PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment-#{project.ubid}", fraud:)
  end

  it "requires a saved payment method even when the old metering flag is disabled" do
    allow(Config).to receive(:premium_ai_metering_enabled).and_return(false)
    expect { described_class.validate_access!(project:, model:) }
      .to raise_error(CloverError, /valid saved payment method/) { expect(it.code).to eq(402) }
  end

  it "does not exempt discounted projects or historical trials" do
    project.update(discount: 100)
    DB[:premium_ai_trial].insert(id: SecureRandom.uuid, project_id: project.id, started_at: Time.now, ends_at: Time.now + 86_400)
    expect { described_class.validate_access!(project:, model:) }.to raise_error(CloverError, /saved payment method/)
  end

  it "requires a non-fraudulent payment method" do
    connect_billing(fraud: true)
    expect { described_class.validate_access!(project:, model:) }.to raise_error(CloverError, /saved payment method/)
  end

  it "allows configured paid models with connected billing" do
    connect_billing
    expect { described_class.validate_access!(project:, model:) }.not_to raise_error
  end

  it "requires the usage collection provider even when another billing provider exists" do
    connect_billing
    allow(Config).to receive_messages(billing_checkout_provider: "polar", polar_access_token: "configured")
    expect { described_class.validate_access!(project:, model:) }.to raise_error(CloverError, /saved payment method/)
  end

  it "rejects Cloudflare preview models without a positive configured rate" do
    connect_billing
    unpriced = CloudflareInferenceModel.new("model_name" => "@cf/unpriced", "tags" => {"capability" => "Text Generation"})
    expect { described_class.validate_access!(project:, model: unpriced) }
      .to raise_error(CloverError, /pricing is configured/) { expect(it.code).to eq(503) }
  end

  it "does not accept display-only prices without an active billing rate" do
    unpriced = CloudflareInferenceModel.new(
      "model_name" => "display-only", "tags" => {"pricing" => {"input" => 1, "output" => 2}},
    )
    expect(described_class.billable_model?(unpriced)).to be(false)
  end

  it "allows input-billed embeddings without an output charge" do
    embedding = CloudflareInferenceModel.new(
      "model_name" => "embedding", "prompt_billing_resource" => "azure-gpt-5-input",
      "tags" => {"capability" => "Embeddings"},
    )
    expect(described_class.billable_model?(embedding)).to be(true)
    expect { described_class.validate_rate!("preview-output") }.to raise_error(CloverError)
  end

  it "pauses additional requests once unbilled paid usage reaches the threshold" do
    connect_billing
    rate = BillingRate.from_resource_properties("InferenceTokens", model.prompt_billing_resource, "global")
    BillingRecord.create(
      project_id: project.id, resource_id: project.id, resource_name: "paid inference",
      billing_rate_id: rate["id"], amount: 1_000_000,
      resource_tags: {paid_inference: true, unit_price: "0.01"},
    )
    expect { described_class.validate_access!(project:, model:) }
      .to raise_error(CloverError, /usage invoice is paid/) { expect(it.code).to eq(402) }
  end

  it "asks for the pending usage invoice to be paid instead of asking for another payment method" do
    connect_billing
    Invoice.create(project_id: project.id, status: "unpaid", billing_kind: "inference_usage", content: {cost: 10},
      begin_time: Time.utc(2026, 9, 16), end_time: Time.utc(2026, 9, 17), invoice_number: "AI-pending")

    expect { described_class.validate_access!(project:, model:) }
      .to raise_error(CloverError, /usage invoice is paid/) { expect(it.code).to eq(402) }
  end
end
