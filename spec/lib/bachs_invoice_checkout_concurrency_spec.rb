# frozen_string_literal: true

require "timeout"
require_relative "../spec_helper"

RSpec.describe BachsInvoiceCheckout, :no_db_transaction do
  before do
    @skip_leaked_thread_check = true
    @project = Project.create(name: "bachs-concurrency-#{SecureRandom.hex(4)}")
    @invoice = Invoice.create(project_id: @project.id, invoice_number: "LR-CONCURRENCY-#{SecureRandom.hex(4)}",
      begin_time: Time.utc(2026, 9), end_time: Time.utc(2026, 10), content: {"cost" => 10.00})
  end

  after do
    DB.transaction do
      DB[:invoice].where(id: @invoice.id).delete if @invoice
      DB[:project].where(id: @project.id).delete if @project
    end
  end

  def start_checkout(invoice)
    account = Struct.new(:email, :name).new("payer@example.com", "Payer")
    described_class.create!(invoice:, project: @project, account:,
      success_url: "https://console.layerrail.com/invoice/success", cancel_url: "https://console.layerrail.com/invoice")
  end

  it "serializes simultaneous browser and collector checkout creation" do
    entered = Queue.new
    release = Queue.new
    requests = Queue.new
    response = {"checkout_id" => "chk_concurrent", "checkout_url" => "https://checkout.bachs.io/c/concurrent", "expires_at" => (Time.now + 3600).iso8601}
    allow(BachsClient).to receive(:create_checkout) do |payload, idempotency_key:|
      requests << [payload, idempotency_key]
      entered << true
      release.pop
      response
    end
    invoices = Array.new(2) { Invoice[@invoice.id] }
    first = Thread.new { start_checkout(invoices.first) }

    begin
      Timeout.timeout(5) { entered.pop }
      committed_request = Invoice[@invoice.id].content.fetch("bachs_checkout")
      expect(committed_request["status"]).to eq("creating")
      expect(JSON.parse(committed_request.fetch("request_body"))).to include("pricing" => {"price_type" => "fixed", "currency" => "USD", "amount" => "10.00"})
      second = Thread.new { start_checkout(invoices.last) }
      sleep 0.1
      expect(second.alive?).to be true
      expect(requests.size).to eq(1)
      release << true
      Timeout.timeout(5) do
        expect(first.value).to eq(second.value)
      end
      expect(requests.size).to eq(1)
      expect(@invoice.refresh.content.dig("bachs_checkout", "checkout_id")).to eq("chk_concurrent")
    ensure
      2.times { release << true }
      first.join(5)
      second&.join(5)
    end
  end

  it "changes an invoice to paid and sends its receipt once across concurrent deliveries" do
    entered = Queue.new
    release = Queue.new
    receipts = Queue.new
    checkout = {
      "checkout_id" => "chk_concurrent", "status" => "completed", "payment_status" => "succeeded",
      "amount" => "10.00", "currency" => "USD",
      "metadata" => {"kind" => "invoice_payment", "invoice" => @invoice.ubid, "project" => @project.ubid},
    }
    allow(BachsClient).to receive(:get_checkout) do
      entered << true
      release.pop
      checkout
    end
    invoices = Array.new(2) { Invoice[@invoice.id] }
    invoices.each { |invoice| allow(invoice).to receive(:send_success_email) { receipts << invoice.id } }
    threads = invoices.map do |invoice|
      Thread.new { described_class.reconcile!(invoice:, checkout_id: "chk_concurrent") }
    end

    begin
      Timeout.timeout(5) { 2.times { entered.pop } }
      2.times { release << true }
      results = Timeout.timeout(5) { threads.map(&:value) }
      expect(results.map { it[:status] }.sort).to eq(%w[already_paid paid])
      expect(receipts.size).to eq(1)
      expect(@invoice.refresh.status).to eq("paid")
    ensure
      2.times { release << true }
      threads.each { it.join(5) }
    end
  end
end
