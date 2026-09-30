# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::InferenceEndpoint do
  it "exposes premium discount metadata with the active paid price" do
    model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == "gpt-6.1-sol" })
    serialized = described_class.serialize(model)

    expect(serialized[:available]).to be(true)
    expect(serialized[:tags]).to include("discount_percent" => 50,
      "standard_pricing" => {"input" => 2.8, "output" => 14.0, "long_context" => {"input" => 5.6, "output" => 21.0}})
    expect(serialized[:price]).to include(per_million_prompt_tokens: 1.4, per_million_completion_tokens: 7.0)
  end

  it "does not imply a Cloudflare premium discount or enable undeployed discounted models" do
    cloudflare_model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == "@cf/meta/llama-3.2-3b-instruct" })
    expect(described_class.serialize(cloudflare_model)[:tags]).not_to have_key("discount_percent")

    model = CloudflareInferenceModel.new(Option::AI_MODELS.find { it["model_name"] == "gpt-6-sol" })
    serialized = described_class.serialize(model)
    expect(serialized[:available]).to be(false)
    expect(serialized[:price][:per_million_prompt_tokens]).to be_nil
    expect(serialized[:tags]).to include("discount_percent" => 50)
  end
end
