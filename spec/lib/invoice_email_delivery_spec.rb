# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe InvoiceEmailDelivery do
  let(:project) { Project.create(name: "invoice-mail") }
  let(:invoice) do
    Invoice.create(project_id: project.id, begin_time: Time.utc(2026, 8), end_time: Time.utc(2026, 9),
      invoice_number: "MAIL-001", status: "paid", content: {"cost" => 1})
  end
  let(:now) { Time.now.utc }
  let(:delivery_options) do
    {invoice:, notification_type: "paid", receivers: ["billing@example.com"], subject: "August invoice",
     body: ["Your usage statement"], attachments: [["invoice.pdf", "original-pdf"]], now:}
  end
  let(:delivery) { DB[:invoice_email_delivery].where(invoice_id: invoice.id, notification_type: "paid") }

  before do |example|
    allow(DB).to receive(:after_commit).and_yield unless example.metadata[:no_db_transaction]
    allow(Config).to receive_messages(mail_driver: :resend, resend_api_key: "re_test")
  end

  after do |example|
    if example.metadata[:no_db_transaction]
      Invoice.where(project_id: project.id).delete(force: true)
      Project.where(id: project.id).delete(force: true)
    end
  end

  it "sends an invoice once and retains a durable accepted marker" do
    described_class.deliver!(**delivery_options)
    described_class.deliver!(**delivery_options)

    expect(Mail::TestMailer.deliveries.length).to eq(1)
    expect(delivery.first).to include(status: "sent", attempts: 1, message: nil)
    expect(delivery.first[:sent_at]).not_to be_nil
    expect(Mail::TestMailer.deliveries.first[described_class::IDEMPOTENCY_HEADER].value).to eq("layerrail-invoice-#{invoice.id}-paid-1")
  end

  it "keeps payment requests and later payment receipts independent" do
    described_class.deliver!(**delivery_options.merge(notification_type: "payment_due"))
    described_class.deliver!(**delivery_options)

    expect(Mail::TestMailer.deliveries.length).to eq(2)
  end

  it "retries an interrupted delivery with identical saved content after its lease" do
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_raise(IOError, "temporary connection failure")
    expect { described_class.deliver!(**delivery_options) }.to raise_error(IOError)
    original_message = delivery.first[:message]
    expect(delivery.first).to include(status: "pending", attempts: 1, last_error_class: "IOError")
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_call_original

    described_class.deliver!(**delivery_options.merge(now: now + 60))
    expect(Mail::TestMailer.deliveries).to be_empty
    described_class.deliver!(**delivery_options.merge(now: now + 301, subject: "Changed subject", attachments: [["invoice.pdf", "changed-pdf"]]))

    expect(Mail::TestMailer.deliveries.length).to eq(1)
    expect(Mail::TestMailer.deliveries.first.subject).to eq(Mail.read_from_string(original_message).subject)
    expect(Mail::TestMailer.deliveries.first.attachments.first.decoded).to eq("original-pdf")
    expect(delivery.first).to include(status: "sent", attempts: 2)
  end

  it "requires reconciliation when an uncertain attempt outlives the provider deduplication window" do
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_raise(IOError, "lost response")
    expect { described_class.deliver!(**delivery_options) }.to raise_error(IOError)
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_call_original

    described_class.deliver!(**delivery_options.merge(now: now + 24 * 60 * 60))

    expect(Mail::TestMailer.deliveries).to be_empty
    expect(delivery.first[:status]).to eq("needs_review")
  end

  it "requires reconciliation if the provider account changes after an uncertain attempt" do
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_raise(IOError, "lost response")
    expect { described_class.deliver!(**delivery_options) }.to raise_error(IOError)
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_call_original
    allow(Config).to receive(:resend_api_key).and_return("different_account")

    described_class.deliver!(**delivery_options.merge(now: now + 301))

    expect(Mail::TestMailer.deliveries).to be_empty
    expect(delivery.first[:status]).to eq("needs_review")
  end

  it "can retry a definitive rejection after the provider deduplication window" do
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_raise(ResendDeliveryError.new(429, "{}"))
    expect { described_class.deliver!(**delivery_options) }.to raise_error(ResendDeliveryError)
    expect(delivery.first[:first_attempt_at]).to be_nil
    expect(delivery.first[:message]).to be_nil
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_call_original

    described_class.deliver!(**delivery_options.merge(now: now + 24 * 60 * 60, receivers: ["corrected@example.com"]))

    expect(Mail::TestMailer.deliveries.length).to eq(1)
    expect(Mail::TestMailer.deliveries.first.to).to eq(["corrected@example.com"])
    expect(Mail::TestMailer.deliveries.first[described_class::IDEMPOTENCY_HEADER].value).to end_with("-2")
  end

  it "does not mark an invoice notified when it has no recipients" do
    expect(described_class.deliver!(**delivery_options.merge(receivers: []))).to be(false)
    expect(delivery.any?).to be(false)
  end

  it "keeps the same generation when a rejection follows a previously ambiguous send" do
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_raise(IOError, "lost accepted response")
    expect { described_class.deliver!(**delivery_options) }.to raise_error(IOError)
    original_message = delivery.first[:message]
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_raise(ResendDeliveryError.new(429, "{}"))
    expect { described_class.deliver!(**delivery_options.merge(now: now + 301)) }.to raise_error(ResendDeliveryError)

    expect(delivery.first).to include(generation: 1, message: original_message)
    expect(delivery.first[:first_attempt_at]).not_to be_nil
    allow_any_instance_of(Mail::Message).to receive(:deliver!).and_call_original
    described_class.deliver!(**delivery_options.merge(now: now + 602, receivers: ["changed@example.com"]))
    expect(Mail::TestMailer.deliveries.first.to).to eq(["billing@example.com"])
    expect(Mail::TestMailer.deliveries.first[described_class::IDEMPOTENCY_HEADER].value).to end_with("-1")
  end

  it "waits for commit and does not send a rolled-back invoice", :no_db_transaction do
    invoice
    DB.transaction(rollback: :always) do
      expect(described_class.deliver!(**delivery_options)).to eq(:queued)
      expect(delivery.any?).to be(false)
      expect(Mail::TestMailer.deliveries).to be_empty
    end
    expect(Mail::TestMailer.deliveries).to be_empty

    DB.transaction do
      expect(described_class.deliver!(**delivery_options)).to eq(:queued)
      expect(Mail::TestMailer.deliveries).to be_empty
    end
    expect(delivery.first[:status]).to eq("sent")
    expect(Mail::TestMailer.deliveries.length).to eq(1)
  end

  it "commits the delivery reservation before contacting the provider", :no_db_transaction do
    expected_invoice_id = invoice.id
    expect_any_instance_of(Mail::Message).to receive(:deliver!) do
      row = Thread.new { DB[:invoice_email_delivery].where(invoice_id: expected_invoice_id).first }.value
      expect(row).to include(status: "sending", attempts: 1)
      expect(row[:message]).to include("August invoice")
    end

    described_class.deliver!(**delivery_options)

    expect(delivery.first[:status]).to eq("sent")
  end
end
