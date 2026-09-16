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
      status: "unpaid",
    )
  end

  def create_checkout_response(id: "chk_invoice_1", expires_at: (Time.now + 3600).iso8601)
    {
      "checkout_id" => id,
      "checkout_url" => "https://checkout.bachs.io/c/#{id}",
      "expires_at" => expires_at,
    }
  end

  def start_checkout(invoice: self.invoice, account: self.account, success_url: "https://console.layerrail.com/invoice/success")
    described_class.create!(invoice:, project:, account:, success_url:, cancel_url: "https://console.layerrail.com/invoice")
  end

  def successful_checkout
    {
      "checkout_id" => "chk_invoice_1",
      "status" => "completed",
      "payment_status" => "succeeded",
      "amount" => "12.34",
      "currency" => "USD",
      "metadata" => {"kind" => "invoice_payment", "invoice" => invoice.ubid, "project" => project.ubid},
    }
  end

  it "creates an exact-amount invoice checkout without a catalog product" do
    expect(BachsClient).not_to receive(:create_product)
    expect(BachsClient).to receive(:create_checkout).with(
      hash_including(
        pricing: {price_type: "fixed", currency: "USD", amount: "12.34"},
        success_url: "https://console.layerrail.com/invoice/success",
        reference: "layerrail-invoice-#{invoice.ubid}-1",
        metadata: hash_including(kind: "invoice_payment", invoice: invoice.ubid),
      ),
      idempotency_key: "layerrail-invoice-checkout-v2-#{invoice.ubid}-1",
    ).and_return(create_checkout_response)

    state = start_checkout

    expect(state).to include("checkout_id" => "chk_invoice_1", "attempt" => 1, "status" => "open")
    expect(state).not_to have_key("product_id")
    expect(invoice.refresh.content["payment_gateway"]).to eq("bachs")
  end

  it "reuses an open checkout even when the caller holds a stale invoice" do
    stale_invoice = Invoice[invoice.id]
    expect(BachsClient).to receive(:create_checkout).once.and_return(create_checkout_response)

    first = start_checkout
    second = start_checkout(invoice: stale_invoice)

    expect(second).to eq(first)
  end

  it "retries a lost provider response with the same persisted body and key" do
    requests = []
    allow(BachsClient).to receive(:create_checkout) do |payload, idempotency_key:|
      requests << [payload, idempotency_key]
      raise BachsAPIError.new(503, "response lost") if requests.length == 1

      create_checkout_response
    end
    expect { start_checkout }.to raise_error(BachsAPIError)
    expect(invoice.refresh.content.dig("bachs_checkout", "status")).to eq("creating")

    other_account = Struct.new(:email, :name).new("another@example.com", "Another billing admin")
    state = start_checkout(account: other_account, success_url: "https://console.layerrail.com/another")

    expect(requests.length).to eq(2)
    expect(requests.last).to eq(requests.first)
    expect(state).to include("checkout_id" => "chk_invoice_1", "attempt" => 1)
  end

  it "creates a fresh checkout after the prior session expires" do
    invoice.content["bachs_checkout"] = {
      "checkout_id" => "chk_expired",
      "checkout_url" => "https://checkout.bachs.io/c/chk_expired",
      "expires_at" => (Time.now - 3600).iso8601,
      "attempt" => 1,
      "status" => "open",
    }
    invoice.save(columns: [:content])
    allow(BachsClient).to receive(:get_checkout).with("chk_expired").and_return("status" => "expired", "payment_status" => "failed")
    expect(BachsClient).to receive(:create_checkout).with(
      hash_including(reference: "layerrail-invoice-#{invoice.ubid}-2"),
      idempotency_key: "layerrail-invoice-checkout-v2-#{invoice.ubid}-2",
    ).and_return(create_checkout_response(id: "chk_invoice_2"))

    state = described_class.create!(invoice:, project:, account:, success_url: "https://example.com/success", cancel_url: "https://example.com/cancel")

    expect(state).to include("checkout_id" => "chk_invoice_2", "attempt" => 2)
  end

  it "requires review when a lost response outlives the provider idempotency window" do
    allow(BachsClient).to receive(:create_checkout).and_raise(BachsAPIError.new(503, "response lost"))
    expect { start_checkout }.to raise_error(BachsAPIError)
    state = invoice.refresh.content.fetch("bachs_checkout")
    state["requested_at"] = (Time.now - 24 * 60 * 60).iso8601
    invoice.save(columns: [:content])
    expect(BachsClient).not_to receive(:create_checkout)

    expect { start_checkout }.to raise_error(BachsAPIError, /payment review/)
    expect(invoice.refresh.content.dig("bachs_checkout", "status")).to eq("review_required")
    expect(invoice.content.dig("bachs_checkout", "attempt")).to eq(1)
    expect { start_checkout }.to raise_error(BachsAPIError, /payment review/)
  end

  it "does not retry an unresolved request under another API key's idempotency scope" do
    allow(Config).to receive(:bachs_api_key).and_return("first-test-key")
    allow(BachsClient).to receive(:create_checkout).and_raise(BachsAPIError.new(503, "response lost"))
    expect { start_checkout }.to raise_error(BachsAPIError)
    allow(Config).to receive(:bachs_api_key).and_return("replacement-test-key")
    expect(BachsClient).not_to receive(:create_checkout)

    expect { start_checkout }.to raise_error(BachsAPIError, /payment review/)
    expect(invoice.refresh.content.dig("bachs_checkout", "reason")).to eq("idempotency_scope_changed")
  end

  %w[processing requires_action requires_confirmation].each do |payment_status|
    it "waits for a #{payment_status} payment instead of opening another checkout" do
      state = create_checkout_response(expires_at: (Time.now - 3600).iso8601).merge("attempt" => 1, "status" => "open")
      invoice.update(content: invoice.content.merge("bachs_checkout" => state))
      allow(BachsClient).to receive(:get_checkout).with("chk_invoice_1").and_return("status" => "expired", "payment_status" => payment_status)
      expect(BachsClient).not_to receive(:create_checkout)

      expect(start_checkout).to eq(state)
      expect(invoice.refresh.status).to eq("unpaid")
    end
  end

  it "reconciles a delayed successful payment before replacing an expired local session" do
    invoice.update(content: invoice.content.merge("bachs_checkout" => create_checkout_response(expires_at: (Time.now - 3600).iso8601).merge("status" => "open")))
    allow(BachsClient).to receive(:get_checkout).with("chk_invoice_1").and_return(successful_checkout)
    expect(BachsClient).not_to receive(:create_checkout)
    expect(invoice).to receive(:send_success_email).once

    expect { start_checkout }.to raise_error(BachsAPIError, /already been paid/)
    expect(invoice.refresh.status).to eq("paid")
  end

  it "does not create checkout for an already paid invoice" do
    invoice.update(status: "paid")
    expect(BachsClient).not_to receive(:create_checkout)

    expect { start_checkout }.to raise_error(BachsAPIError, /not payable/)
  end

  it "rejects amounts below the documented USD minimum" do
    invoice.update(content: {"cost" => 0.75})
    expect(BachsClient).not_to receive(:create_checkout)

    expect { start_checkout }.to raise_error(ArgumentError, /at least USD 1.00/)
  end

  it "marks only a matching successful checkout as paid" do
    invoice.content["bachs_checkout"] = {"checkout_id" => "chk_invoice_1", "product_id" => "prod_invoice_1", "status" => "open"}
    invoice.save(columns: [:content])
    allow(BachsClient).to receive(:get_checkout).with("chk_invoice_1").and_return(successful_checkout)
    expect(BachsClient).to receive(:archive_product).with("prod_invoice_1").once
    expect(invoice).to receive(:send_success_email).once

    expect(described_class.reconcile!(invoice:, checkout_id: "chk_invoice_1")[:status]).to eq("paid")
    expect(described_class.reconcile!(invoice:, checkout_id: "chk_invoice_1")[:status]).to eq("already_paid")
    expect(invoice.refresh.status).to eq("paid")
    expect(invoice.content["payment_gateway"]).to eq("bachs")
  end

  it "rejects a payment whose amount would only match after rounding" do
    allow(BachsClient).to receive(:get_checkout).and_return(successful_checkout.merge("amount" => "12.344"))
    expect(invoice).not_to receive(:send_success_email)

    expect(described_class.reconcile!(invoice:, checkout_id: "chk_invoice_1")[:status]).to eq("not_paid")
    expect(invoice.refresh.status).to eq("unpaid")
  end

  it "checks the persisted invoice amount instead of a stale caller's amount" do
    stale_invoice = Invoice[invoice.id]
    invoice.update(content: {"cost" => 20.00})
    allow(BachsClient).to receive(:get_checkout).and_return(successful_checkout)

    expect(described_class.reconcile!(invoice: stale_invoice, checkout_id: "chk_invoice_1")[:status]).to eq("not_paid")
    expect(invoice.refresh.status).to eq("unpaid")
  end

  it "finds an invoice webhook by its public UBID" do
    event = {
      "type" => "collection.succeeded",
      "data" => {"checkout_id" => "chk_invoice_1", "metadata" => {"kind" => "invoice_payment", "invoice" => invoice.ubid}},
    }
    expect(described_class).to receive(:reconcile!).with(invoice:, checkout_id: "chk_invoice_1").and_return(status: "paid")

    expect(described_class.reconcile_event!(event)).to eq(status: "paid")
  end

  it "ignores non-invoice webhook metadata" do
    event = {
      "type" => "collection.succeeded",
      "data" => {
        "checkout_id" => "chk_game_1",
        "metadata" => {"kind" => "game_vps_checkout"},
      },
    }
    expect(described_class).not_to receive(:reconcile!)

    expect(described_class.reconcile_event!(event)).to eq(status: "ignored")
  end
end
