# frozen_string_literal: true

require "pdf-reader"
require_relative "spec_helper"

RSpec.describe Invoice, "PDF retrieval" do
  subject(:invoice) do
    described_class.create(project_id: project.id, begin_time: Time.utc(2025, 3), end_time: Time.utc(2025, 4),
      invoice_number: "HISTORICAL-001", created_at: Time.utc(2025, 4), status: "paid",
      content: {"cost" => 10, "subtotal" => 11, "credit" => 1, "discount" => 0, "resources" => [],
                "billing_info" => {"id" => SecureRandom.uuid, "name" => "Historical Customer", "country" => "US"},
                "payment_gateway" => "polar", "payment_method" => {"stripe_id" => "bachs:payment:old-checkout"}})
  end

  let(:project) { Project.create(name: "invoice-history") }
  let(:client) { instance_double(Aws::S3::Client) }

  before do
    allow(DB).to receive(:after_commit).and_yield
    allow(Config).to receive_messages(invoices_blob_storage_endpoint: "https://invoices.example.com",
      invoices_blob_storage_access_key: "test-access-key", invoices_blob_storage_secret_key: "test-secret-key")
    allow(described_class).to receive(:blob_storage_client).and_return(client)
  end

  def pdf_text(pdf)
    PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join(" ")
  end

  it "renders the saved invoice when optional storage is unconfigured without requesting live billing details" do
    allow(Config).to receive(:invoices_blob_storage_endpoint).and_return(nil)
    expect(described_class).not_to receive(:blob_storage_client)
    expect(PolarClient).not_to receive(:get_customer_by_external_id)
    expect(BillingInfo).not_to receive(:[])
    original_content = invoice.content.to_h.dup

    text = pdf_text(invoice.pdf)

    expect(text).to include("Historical Customer", "HISTORICAL-001", "$11.00", "-$1.00", "$10.00")
    expect(invoice.reload.content).to eq(original_content)
    expect(invoice.status).to eq("paid")
  end

  it "renders historical invoices without saved billing or issuer details" do
    allow(Config).to receive(:invoices_blob_storage_secret_key).and_return(nil)
    invoice.update(content: invoice.content.merge("billing_info" => nil, "issuer_info" => nil))

    expect(pdf_text(invoice.pdf)).to include("HISTORICAL-001", "$10.00")
  end

  it "returns the archived PDF unchanged when storage is available" do
    stored_response = Aws::S3::Types::GetObjectOutput.new(body: StringIO.new("archived-pdf-bytes"))
    expect(client).to receive(:get_object).with(bucket: Config.invoices_bucket_name, key: invoice.blob_key).and_return(stored_response)
    expect(invoice).not_to receive(:generate_pdf)

    expect(invoice.pdf).to eq("archived-pdf-bytes")
  end

  [Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NoSuchBucket, Aws::S3::Errors::AccessDenied, Aws::S3::Errors::NotEntitled].each do |error_class|
    it "regenerates the saved invoice when storage returns #{error_class.name}" do
      expect(client).to receive(:get_object).and_raise(error_class.new(nil, "storage unavailable"))
      original_content = invoice.content.to_h.dup

      expect(pdf_text(invoice.pdf)).to include("HISTORICAL-001", "$11.00", "-$1.00", "$10.00")
      expect(invoice.reload.content).to eq(original_content)
      expect(invoice.status).to eq("paid")
    end
  end

  it "regenerates the saved invoice when storage credentials are missing" do
    expect(described_class).to receive(:blob_storage_client).and_raise(Aws::Errors::MissingCredentialsError)

    expect(pdf_text(invoice.pdf)).to include("HISTORICAL-001", "$10.00")
  end

  it "regenerates the saved invoice when the storage connection fails" do
    expect(client).to receive(:get_object).and_raise(Seahorse::Client::NetworkingError.new(IOError.new("connection closed")))

    expect(pdf_text(invoice.pdf)).to include("HISTORICAL-001", "$10.00")
  end

  it "makes one bounded storage attempt before regenerating a timed-out PDF" do
    allow(described_class).to receive(:blob_storage_client).and_call_original
    request = stub_request(:get, %r{\Ahttps://(?:[a-z0-9-]+\.)?invoices\.example\.com/}).to_timeout
    storage_config = described_class.blob_storage_client.config

    expect(storage_config.http_open_timeout).to be <= 5
    expect(storage_config.http_read_timeout).to be <= 10
    expect(pdf_text(invoice.pdf)).to include("HISTORICAL-001", "$10.00")
    expect(request).to have_been_requested.once
  end

  it "does not hide unrelated programming errors" do
    expect(client).to receive(:get_object).and_raise(TypeError, "invalid response")

    expect { invoice.pdf }.to raise_error(TypeError, "invalid response")
  end

  it "sends the saved invoice attachment when optional storage is not entitled" do
    invoice.update(content: invoice.content.merge("billing_info" => invoice.content["billing_info"].merge("email" => "billing@example.com")))
    original_content = invoice.content.to_h.dup
    expect(client).to receive(:put_object).and_raise(Aws::S3::Errors::NotEntitled.new(nil, "private storage response"))
    expect(Clog).to receive(:emit).with("Could not archive invoice PDF", {
      invoice_pdf_storage_unavailable: {invoice_ubid: invoice.ubid, error_class: "Aws::S3::Errors::NotEntitled"},
    })

    invoice.send_success_email

    delivery = Mail::TestMailer.deliveries.last
    expect(delivery.to).to eq(["billing@example.com"])
    expect(delivery.attachments.map(&:filename)).to eq([invoice.filename])
    expect(pdf_text(delivery.attachments.first.decoded)).to include("HISTORICAL-001", "$11.00", "-$1.00", "$10.00")
    expect(invoice.reload.content).to eq(original_content)
    expect(invoice.status).to eq("paid")
  end

  it "sends the invoice attachment when optional storage is not configured" do
    allow(Config).to receive(:invoices_blob_storage_endpoint).and_return(nil)
    invoice.update(content: invoice.content.merge("billing_info" => invoice.content["billing_info"].merge("email" => "billing@example.com")))
    expect(described_class).not_to receive(:blob_storage_client)

    invoice.send_success_email

    expect(Mail::TestMailer.deliveries.last.attachments.map(&:filename)).to eq([invoice.filename])
  end

  it "does not hide unrelated programming errors during optional archiving" do
    expect(client).to receive(:put_object).and_raise(TypeError, "invalid payload")

    expect { invoice.archive_pdf("pdf-bytes") }.to raise_error(TypeError, "invalid payload")
  end

  it "still reports a failure when storage archiving is explicitly requested" do
    expect(client).to receive(:put_object).and_raise(Aws::S3::Errors::NotEntitled.new(nil, "storage unavailable"))

    expect { invoice.persist("pdf-bytes") }.to raise_error(Aws::S3::Errors::NotEntitled)
  end
end
