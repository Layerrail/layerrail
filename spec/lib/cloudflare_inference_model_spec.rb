# frozen_string_literal: true

RSpec.describe CloudflareInferenceModel do
  it "keeps Cloudflare catalog identifiers unique and usable" do
    models = Option::AI_MODELS.select { it["provider"] == "cloudflare" }
    names = models.map { it.fetch("model_name") }
    expect(names).to all(match(%r{\A(?:@(?:cf|hf)/|minimax/).+}))
    expect(names.uniq).to eq(names)
    expect(models.map { it.fetch("id") }.uniq.length).to eq(models.length)
  end

  it "uses provided id when present" do
    model = described_class.new({
      "id" => "azure-openai-gpt-5",
      "model_name" => "gpt-5",
      "provider" => "azure_foundry",
      "tags" => {}
    })

    expect(model.ubid).to eq("azure-openai-gpt-5")
  end

  it "derives a stable fallback id when id is missing" do
    model = described_class.new({
      "model_name" => "gpt-5.6-luna",
      "provider" => "azure_foundry",
      "tags" => {}
    })

    expect(model.ubid).to eq("azure-foundry-gpt-5-6-luna")
  end

  it "exposes verified Cloudflare prices and cache discounts in the API catalog" do
    model = described_class.new(Option::AI_MODELS.find { it["model_name"] == "@cf/moonshotai/kimi-k2.6" })
    serialized = Serializers::InferenceEndpoint.serialize(model)
    expect(serialized[:available]).to be(true)
    expect(serialized[:price]).to eq(
      per_million_prompt_tokens: 1.045,
      per_million_completion_tokens: 4.4,
      per_million_cached_prompt_tokens: 0.176,
    )
  end

  it "does not expose misleading prices for a model whose metering is unavailable" do
    model = described_class.new(Option::AI_MODELS.find { it["model_name"] == "@cf/baai/bge-small-en-v1.5" })
    serialized = Serializers::InferenceEndpoint.serialize(model)
    expect(serialized[:available]).to be(false)
    expect(serialized[:price].values).to all(be_nil)
  end

  it "registers MiniMax M3 with the exact unified catalog ID and a gated billing state" do
    model = described_class.new(Option::AI_MODELS.find { it["model_name"] == "minimax/m3" })
    expect(model.provider).to eq("cloudflare")
    expect(model.tags).to include("api" => "chat", "context_length" => "1M", "billing_status" => "awaiting_gateway_credits")
    expect(PremiumAiUsageMeter.billable_model?(model)).to be(false)
  end
end
