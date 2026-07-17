# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BachsInvoiceCheckout do
  let(:project) { Project.create(name: "project-1") }
  let(:account) { Struct.new(:email, :name).new("customer@example.com", "Customer") }
  let(:invoice) do
    Invoice.create(
      project_id: project.id,
      begin_time: Time.utc(2026, 6),
      end_time: Time.utc(2026, 7),
      invoice_number: "LR-2026-001",
      created_at: Time.now,
      content: {"cost" => 12.34},
      status: "unpaid"
    )
  end

  def create_checkout_response(id: "chk_invoice_1", expires_at: (Time.now + 3600).iso8601)
    {
      "checkout_id" => id,
      "checkout_url" => "https://checkout.bachs.io/c/#{id}",
      "expires_at" => expires_at
    }
  end

  it "creates a one-time invoice checkout with a retry-safe reference" do
    allow(BachsClient).to receive(:create_product).and_return("id" => "prod_invoice_1")
    expect(BachsClient).to receive(:create_checkout).with(
      hash_including(
        product_cart: [{product_id: "prod_invoice_1", quantity: 1}],
        success_url: "https://console.layerrail.com/invoice/success",
        reference: "layerrail-invoice-#{invoice.ubid}-1",
        metadata: hash_including("kind" => "invoice_payment", "invoice" => invoice.ubid)
      ),
      idempotency_key: "layerrail-invoice-checkout-#{invoice.ubid}-1"
    ).and_return(create_checkout_response)

    state = described_class.create!(
      invoice:,
      project:,
      account:,
      success_url: "https://console.layerrail.com/invoice/success",
      cancel_url: "https://console.layerrail.com/invoice"
    )

    expect(state).to include("checkout_id" => "chk_invoice_1", "attempt" => 1, "status" => "open")
    expect(invoice.refresh.content["payment_gateway"]).to eq("bachs")
  end

  it "creates a fresh checkout after the prior session expires" do
    invoice.content["bachs_checkout"] = {
      "checkout_id" => "chk_expired",
      "checkout_url" => "https://checkout.bachs.io/c/chk_expired",
      "expires_at" => (Time.now - 3600).iso8601,
      "attempt" => 1,
      "status" => "open"
    }
    invoice.save(columns: [:content])
    allow(BachsClient).to receive(:create_product).and_return("id" => "prod_invoice_1")
    expect(BachsClient).to receive(:create_checkout).with(
      hash_including(reference: "layerrail-invoice-#{invoice.ubid}-2"),
      idempotency_key: "layerrail-invoice-checkout-#{invoice.ubid}-2"
    ).and_return(create_checkout_response(id: "chk_invoice_2"))

    state = described_class.create!(invoice:, project:, account:, success_url: "https://example.com/success", cancel_url: "https://example.com/cancel")

    expect(state).to include("checkout_id" => "chk_invoice_2", "attempt" => 2)
  end

  it "marks only a matching successful checkout as paid" do
    checkout = {
      "checkout_id" => "chk_invoice_1",
      "status" => "COMPLETED",
      "payment_status" => "succeeded",
      "amount" => "12.34",
      "currency" => "USD",
      "metadata" => {"kind" => "invoice_payment", "invoice" => invoice.ubid, "project" => project.ubid}
    }
    invoice.content["bachs_checkout"] = {"checkout_id" => "chk_invoice_1", "product_id" => "prod_invoice_1", "status" => "open"}
    invoice.save(columns: [:content])
    allow(BachsClient).to receive(:get_checkout).with("chk_invoice_1").and_return(checkout)
    allow(BachsClient).to receive(:archive_product).with("prod_invoice_1")
    allow(invoice).to receive(:send_success_email)

    expect(described_class.reconcile!(invoice:, checkout_id: "chk_invoice_1")[:status]).to eq("paid")
    expect(invoice.refresh.status).to eq("paid")
    expect(invoice.content["payment_gateway"]).to eq("bachs")
    expect(BachsClient).to have_received(:archive_product).with("prod_invoice_1")
  end

  it "ignores non-invoice webhook metadata" do
    event = {
      "type" => "collection.succeeded",
      "data" => {
        "checkout_id" => "chk_game_1",
        "metadata" => {"kind" => "game_vps_checkout"}
      }
    }
    expect(described_class).not_to receive(:reconcile!)

    expect(described_class.reconcile_event!(event)).to eq(status: "ignored")
  end
end
