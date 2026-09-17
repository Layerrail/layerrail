# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe MonthlyInvoiceFinalizer do
  let(:month) { Date.new(2026, 8, 1) }
  let(:project) { Project.create(name: "monthly-invoice") }
  let(:invoice) do
    Invoice.create(project_id: project.id, begin_time: Time.utc(2026, 8), end_time: Time.utc(2026, 9),
      invoice_number: "MONTH-001", status: "paid", content: {"cost" => 10})
  end

  it "starts automatic finalization in September without resending unaudited August history" do
    expect(described_class.due_months(now: Time.utc(2026, 9, 17))).to eq([])
    expect(described_class.due_months(now: Time.utc(2026, 10, 1))).to eq([Date.new(2026, 9, 1)])
    expect(described_class.due_months(now: Time.utc(2026, 11, 1))).to eq([Date.new(2026, 9, 1), Date.new(2026, 10, 1)])
  end

  it "rejects partial or future invoice months" do
    expect { described_class.new(month: Date.new(2026, 9, 1), now: Time.utc(2026, 9, 17)) }.to raise_error(ArgumentError, /completed months/)
  end

  it "retries notifications for existing invoices without regenerating or charging them" do
    invoice
    expect(InvoiceGenerator).not_to receive(:new)
    expect_any_instance_of(Invoice).not_to receive(:charge)
    expect_any_instance_of(Invoice).to receive(:send_success_email)

    expect(described_class.new(month:).run).to include(projects: 1, created: 0, processed: 1, failed: 0)
  end

  it "continues to the next invoice when one notification fails" do
    invoice
    other_project = Project.create(name: "second-monthly")
    Invoice.create(project_id: other_project.id, begin_time: Time.utc(2026, 8), end_time: Time.utc(2026, 9),
      invoice_number: "MONTH-002", status: "paid", content: {"cost" => 10})
    attempted = []
    allow_any_instance_of(Invoice).to receive(:send_success_email) do |current|
      attempted << current.id
      raise "mail unavailable" if current.id == invoice.id
    end

    result = described_class.new(month:).run

    expect(attempted.length).to eq(2)
    expect(result).to include(projects: 2, created: 0, processed: 1, failed: 1)
  end

  it "supports a read-only preview scoped to selected projects" do
    invoice
    expect(InvoiceGenerator).not_to receive(:new)
    expect_any_instance_of(Invoice).not_to receive(:send_success_email)

    expect(described_class.new(month:, project_ids: [project.id], dry_run: true).run).to include(projects: 1, processed: 0, dry_run: true)
    expect(described_class.new(month:, project_ids: [SecureRandom.uuid], dry_run: true).run).to include(projects: 0, processed: 0)
  end

  it "does not include separately billed AI usage invoices" do
    invoice.update(billing_kind: "inference_usage")
    expect_any_instance_of(Invoice).not_to receive(:send_success_email)

    expect(described_class.new(month:).run).to include(projects: 0, processed: 0)
  end

  it "sends a zero-cost historical statement without a payment request or card charge and does not duplicate it" do
    allow(DB).to receive(:after_commit).and_yield
    allow(Config).to receive(:invoices_blob_storage_endpoint).and_return(nil)
    invoice.update(status: "unpaid", content: {
      "cost" => 0, "subtotal" => 0, "credit" => 0, "discount" => 0,
      "resources" => [], "billing_info" => {"email" => "billing@example.com", "country" => "US"},
    })
    expect(BachsClient).not_to receive(:create_checkout)
    expect(StripeClient).not_to receive(:payment_intents)

    described_class.new(month:).run
    described_class.new(month:).run

    expect(invoice.reload.status).to eq("below_minimum_threshold")
    expect(Mail::TestMailer.deliveries.length).to eq(1)
    expect(Mail::TestMailer.deliveries.first.html_part.decoded).to include("there will be no charges for this month")
    expect(Mail::TestMailer.deliveries.first.subject).to include("August 2026")
  end
end
