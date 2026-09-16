# frozen_string_literal: true

RSpec.describe CloudflareInferenceModel do
  it "keeps Cloudflare catalog identifiers unique and usable" do
    models = Option::AI_MODELS.select { it["provider"] == "cloudflare" }
    names = models.map { it.fetch("model_name") }
    expect(names).to all(match(%r{\A(?:@(?:cf|hf)/)?[^/]+/.+}))
    expect(names.uniq).to eq(names)
    expect(models.map { it.fetch("id") }.uniq.length).to eq(models.length)
    expect(models.map { it.fetch("tags").fetch("billing_status") }).to all(be_a(String))
    expect(models.length).to eq(239)
    expect(models.count { PremiumAiUsageMeter.billable_model?(described_class.new(it)) }).to eq(26)
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
    expect(model.tags).to include("api" => "chat", "billing_status" => "catalog_only")
    expect(PremiumAiUsageMeter.billable_model?(model)).to be(false)
  end

  it "quotes every numeric Cloudflare catalog price with exactly ten percent markup" do
    quotes = Option::AI_MODELS.select { it["provider"] == "cloudflare" }.flat_map { it.fetch("tags").fetch("catalog_prices") }
    expect(quotes.length).to be >= 596
    quotes.each do |quote|
      provider_price = quote["provider_price"]
      next unless provider_price

      if BigDecimal(provider_price).positive?
        expect(BigDecimal(quote.fetch("price"))).to eq(BigDecimal(provider_price) * BigDecimal("1.10"))
      else
        expect(quote["price"]).to be_nil
      end
    end
  end

  it "shows MiniMax tier quotes while keeping actual billing rates unavailable" do
    model = described_class.new(Option::AI_MODELS.find { it["model_name"] == "minimax/m3" })
    serialized = Serializers::InferenceEndpoint.serialize(model)
    quotes = serialized.fetch(:catalog_prices).to_h { [it.fetch("label"), it["price"]] }
    expect(quotes).to include("Input <=512k (per 1M)" => "0.33", "Input >512k (per 1M)" => "1.32", "Output >512k (per 1M)" => "5.28")
    expect(serialized[:available]).to be(false)
    expect(serialized[:price].values).to all(be_nil)
  end

  it "prices new native models with separate discounted cached input" do
    model = described_class.new(Option::AI_MODELS.find { it["model_name"] == "@cf/deepseek-ai/deepseek-v4-flash-0731" })
    expect(model.tags).to include("api" => "run", "cache_usage_optional" => true)
    expect(Serializers::InferenceEndpoint.serialize(model)).to include(
      available: true,
      price: {per_million_prompt_tokens: 0.484, per_million_completion_tokens: 1.452, per_million_cached_prompt_tokens: 0.0154},
    )
  end
end
