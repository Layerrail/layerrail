# frozen_string_literal: true

RSpec.describe CloudflareInferenceModel do
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
end
