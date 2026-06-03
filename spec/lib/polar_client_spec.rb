# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PolarClient do
  before do
    allow(Config).to receive(:polar_access_token).and_return("polar_test")
    allow(Config).to receive(:polar_api_base_url).and_return("https://api.polar.test/v1")
  end

  it "updates a product" do
    request = stub_request(:patch, "https://api.polar.test/v1/products/product_123")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        },
        body: hash_including(
          name: "LayerRail Verification Package",
          prices: [hash_including(price_amount: 100)]
        )
      )
      .to_return(status: 200, body: JSON.generate({"id" => "product_123"}))

    expect(described_class.update_product("product_123", {
      name: "LayerRail Verification Package",
      prices: [{amount_type: "fixed", price_currency: "usd", price_amount: 100}]
    })).to eq({"id" => "product_123"})
    expect(request).to have_been_requested
  end
end
