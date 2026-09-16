# frozen_string_literal: true

RSpec.describe InferenceUsageCollection do
  let(:project) { Project.create(name: "paid-ai") }
  let(:now) { Time.now.utc.round }
  let(:invoice) do
    Invoice.create(project_id: project.id, billing_kind: "inference_usage", invoice_number: "AI-001",
      begin_time: now - 3600, end_time: now, content: {"cost" => 10.0, "billing_info" => {"email" => "billing@example.com", "name" => "Customer"}})
  end

  before do
    allow(BachsClient).to receive(:invoice_checkout_enabled?).and_return(true)
    allow_any_instance_of(Invoice).to receive(:send_payment_due_email)
    allow_any_instance_of(Invoice).to receive(:send_success_email)
  end

  it "creates a hosted checkout without marking the invoice paid or repeatedly notifying" do
    expect(BachsInvoiceCheckout).to receive(:create!).once.with(hash_including(invoice: an_instance_of(Invoice),
      success_url: "#{Config.base_url}#{project.path}/billing/invoice/#{invoice.ubid}/success"))
    described_class.collect!(invoice, now:)
    described_class.collect!(invoice, now: now + 60)
    expect(invoice.reload.status).to eq("unpaid")
    expect(invoice.content["usage_collection"]["notified_at"]).to eq(now.iso8601)
  end

  it "retries a provider failure after the backoff using the same invoice" do
    expect(BachsInvoiceCheckout).to receive(:create!).ordered.and_raise(BachsAPIError.new(503, "temporary"))
    expect(BachsInvoiceCheckout).to receive(:create!).ordered
    expect { described_class.collect!(invoice, now:) }.to raise_error(BachsAPIError)
    described_class.collect!(invoice, now: now + 60)
    described_class.collect!(invoice, now: now + 301)
    expect(invoice.reload.status).to eq("unpaid")
    expect(Invoice.where(project_id: project.id).count).to eq(1)
  end

  it "reconciles an existing payment before attempting another checkout" do
    invoice.update(content: invoice.content.merge("bachs_checkout" => {"checkout_id" => "chk_paid"}))
    expect(BachsInvoiceCheckout).to receive(:reconcile!).with(invoice: an_instance_of(Invoice), checkout_id: "chk_paid").and_return(status: "paid")
    expect(BachsInvoiceCheckout).not_to receive(:create!)
    described_class.collect!(invoice, now:)
  end

  it "settles fully credited usage without calling Bachs" do
    invoice.update(content: invoice.content.merge("cost" => 0))
    expect(BachsInvoiceCheckout).not_to receive(:create!)
    described_class.collect!(invoice, now:)
    expect(invoice.reload.status).to eq("paid")
  end

  it "retries a failed payment-due email without losing its notification" do
    allow(BachsInvoiceCheckout).to receive(:create!)
    allow_any_instance_of(Invoice).to receive(:send_payment_due_email).and_raise("SMTP unavailable")
    expect { described_class.collect!(invoice, now:) }.to raise_error("SMTP unavailable")
    expect(invoice.reload.content["usage_collection"]["notified_at"]).to be_nil
    allow_any_instance_of(Invoice).to receive(:send_payment_due_email).and_return(true)
    described_class.collect!(invoice, now: now + 301)
    expect(invoice.reload.content["usage_collection"]["notified_at"]).not_to be_nil
  end
end
