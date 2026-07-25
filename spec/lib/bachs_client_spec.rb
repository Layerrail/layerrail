# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BachsClient do
  before do
    allow(Config).to receive(:bachs_api_key).and_return("bachs_test")
    allow(Config).to receive(:bachs_api_base_url).and_return("https://api.bachs.test")
  end

  it "updates a product price" do
    payload = {price: {price_type: "fixed", currency: "USD", amount: "16.00"}}
    request = stub_request(:patch, "https://api.bachs.test/v1/products/prod_growth")
      .with(
        headers: {
          "Authorization" => "Bearer bachs_test",
          "Content-Type" => "application/json"
        },
        body: JSON.generate(payload)
      )
      .to_return(status: 200, body: JSON.generate("id" => "prod_growth", "price" => payload[:price]))

    product = described_class.update_product("prod_growth", payload)

    expect(product).to eq("id" => "prod_growth", "price" => {"price_type" => "fixed", "currency" => "USD", "amount" => "16.00"})
    expect(request).to have_been_requested
  end

  it "creates an idempotent verification refund" do
    request = stub_request(:post, "https://api.bachs.test/v1/refunds")
      .with(
        headers: {
          "Authorization" => "Bearer bachs_test",
          "Content-Type" => "application/json",
          "Idempotency-Key" => "refund-checkout-1"
        },
        body: JSON.generate(
          charge_id: "pay_1",
          reference: "refund-checkout-1",
          reason: "Automatic LayerRail billing verification refund",
          idempotency_key: "refund-checkout-1"
        )
      )
      .to_return(status: 201, body: JSON.generate("refund_id" => "ref_1", "status" => "processing"))

    refund = described_class.create_refund(
      {
        charge_id: "pay_1",
        reference: "refund-checkout-1",
        reason: "Automatic LayerRail billing verification refund",
        idempotency_key: "refund-checkout-1"
      },
      idempotency_key: "refund-checkout-1"
    )

    expect(refund).to eq("refund_id" => "ref_1", "status" => "processing")
    expect(request).to have_been_requested
  end
end
