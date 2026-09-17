# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BachsClient do
  before do
    allow(Config).to receive(:bachs_api_key).and_return("bachs_test")
    allow(Config).to receive(:bachs_api_base_url).and_return("https://api.bachs.test")
  end

  it "opens a fresh portal session using the documented response contract" do
    request = stub_request(:post, "https://api.bachs.test/v1/customers/cust_1/portal-sessions")
      .with(headers: {"Authorization" => "Bearer bachs_test"})
      .to_return(status: 200, body: JSON.generate("id" => "psn_1", "url" => "https://portal.bachs.io/s/test-only"))

    2.times do
      expect(described_class.create_customer_portal_session("cust_1")).to eq("id" => "psn_1", "url" => "https://portal.bachs.io/s/test-only")
    end
    expect(request).to have_been_requested.twice
  end

  it "searches customer emails with correctly encoded query parameters" do
    request = stub_request(:get, "https://api.bachs.test/v1/customers")
      .with(query: {search: "owner+billing@example.com", limit: "100"})
      .to_return(status: 200, body: JSON.generate("items" => [], "pagination" => {"has_more" => false}))

    expect(described_class.list_customers(search: "owner+billing@example.com")).to include("items" => [])
    expect(request).to have_been_requested
  end

  it "passes a stable idempotency key when creating a billing customer" do
    payload = {email: "owner@example.com", name: "Owner"}
    request = stub_request(:post, "https://api.bachs.test/v1/customers")
      .with(headers: {"Idempotency-Key" => "billing-customer-1"}, body: JSON.generate(payload))
      .to_return(status: 201, body: JSON.generate("customer_id" => "cust_1", "email" => payload[:email]))

    expect(described_class.create_customer(payload, idempotency_key: "billing-customer-1")).to include("customer_id" => "cust_1")
    expect(request).to have_been_requested
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
