# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "Bachs webhook" do
  let(:secret) { "bachs-test-webhook-secret" }
  let(:project) { Project.create(name: "bachs-webhook-project") }
  let(:invoice) do
    Invoice.create(project_id: project.id, begin_time: Time.utc(2026, 9), end_time: Time.utc(2026, 10),
      invoice_number: "LR-BACHS-WEBHOOK", content: {"cost" => 10.00})
  end
  let(:event) do
    {type: "collection.succeeded", data: {checkout_id: "chk_invoice_1", metadata: {kind: "invoice_payment", invoice: invoice.ubid}}}
  end

  before do
    allow(BachsClient).to receive(:enabled?).and_return(true)
    allow(Config).to receive(:bachs_webhook_secret).and_return(secret)
  end

  it "rejects an invalid signature before looking up payment" do
    expect(BachsClient).not_to receive(:get_checkout)
    send_webhook(signature: "invalid")
    expect(page.status_code).to eq(401)
  end

  it "rejects a stale signed event" do
    expect(BachsClient).not_to receive(:get_checkout)
    send_webhook(timestamp: Time.now.to_i - 301)
    expect(page.status_code).to eq(401)
  end

  it "requests retry after a provider lookup failure" do
    expect(BachsClient).to receive(:get_checkout).with("chk_invoice_1").and_raise(BachsAPIError.new(503, "temporarily unavailable"))
    send_webhook
    expect(page.status_code).to eq(503)
    expect(invoice.refresh.status).to eq("unpaid")
  end

  it "requests retry instead of acknowledging an unexpected reconciliation failure" do
    expect(BachsClient).to receive(:get_checkout).with("chk_invoice_1").and_raise(StandardError, "database unavailable")
    send_webhook
    expect(page.status_code).to eq(503)
    expect(invoice.refresh.status).to eq("unpaid")
  end

  def send_webhook(timestamp: Time.now.to_i, signature: nil)
    body = JSON.generate(event)
    signature ||= OpenSSL::HMAC.hexdigest("sha256", secret, "#{timestamp}.#{body}")
    page.driver.post("/webhook/bachs", body,
      {"Content-Type" => "application/json", "HTTP_X_BACHS_TIMESTAMP" => timestamp.to_s, "HTTP_X_BACHS_SIGNATURE" => signature})
  end
end
