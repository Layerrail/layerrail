# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::InferenceEndpoint do
  {"gpt-6.1-sol" => [1.4, 7.0, 5.6, 21.0], "gpt-6-sol" => [1.4, 7.0, 5.6, 21.0], "gpt-6-luna" => [0.07, 0.35, 0.28, 1.05]}.each do |name, prices|
    it "exposes #{name} as available with its discount metadata and active paid price" do
      model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == name })
      serialized = described_class.serialize(model)

      expect(serialized[:available]).to be(true)
      expect(serialized[:tags]).to include("discount_percent" => 50,
        "standard_pricing" => include("input" => prices[0] * 2, "output" => prices[1] * 2,
          "long_context" => include("input" => prices[2], "output" => prices[3])))
      expect(serialized[:price]).to include(per_million_prompt_tokens: prices[0], per_million_completion_tokens: prices[1])
    end
  end

  it "does not imply a Cloudflare premium discount" do
    cloudflare_model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == "@cf/meta/llama-3.2-3b-instruct" })
    expect(described_class.serialize(cloudflare_model)[:tags]).not_to have_key("discount_percent")
  end

  it "does not enable an unavailable Azure deployment merely because it has discounted prices" do
    source = Option::AI_MODELS.find { it["model_name"] == "gpt-6.1-sol" }
    unavailable = source.merge("id" => "azure-unavailable-serializer-test", "model_name" => "unavailable-azure-model",
      "tags" => source.fetch("tags").merge("deployment" => "unavailable-azure-model", "availability" => "unavailable",
        "billing_status" => "catalog_only"))
    model = CloudflareInferenceModel.new(unavailable)
    serialized = described_class.serialize(model)
    expect(serialized[:available]).to be(false)
    expect(serialized[:price][:per_million_prompt_tokens]).to be_nil
    expect(serialized[:tags]).to include("discount_percent" => 50)
  end
end
