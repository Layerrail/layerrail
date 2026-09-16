# frozen_string_literal: true

RSpec.describe InferenceUsageBilling do
  let(:project) { Project.create(name: "paid-ai") }
  let(:now) { Time.utc(2026, 9, 16, 12) }
  let(:rate) { BillingRate.from_resource_type("InferenceTokens").find { it["unit_price"].positive? } }

  def usage(amount, at: now - 60, paid: true)
    BillingRecord.create(project_id: project.id, resource_id: project.id, resource_name: "AI tokens",
      billing_rate_id: rate.fetch("id"), amount:, span: Sequel.pg_range(at...(at + 1)),
      resource_tags: paid ? {"paid_inference" => true, "unit_price" => "0.001"} : {})
  end

  def settle(at: now)
    described_class.settle!(project:, eur_rate: 0.9, now: at)
  end

  it "waits for ten dollars, then allocates usage only once" do
    record = usage(9999)
    expect(settle).to be_nil
    record.update(amount: 10_000)
    invoice = settle
    expect(invoice.billing_kind).to eq("inference_usage")
    expect(invoice.cost).to eq(10.0)
    expect(record.reload.inference_invoiced_amount).to eq(10_000)
    expect(settle).to be_nil
    expect(project.invoices_dataset.count).to eq(1)
  end

  it "allocates only the next increment after payment" do
    record = usage(10_000)
    first = settle
    record.update(amount: 20_000)
    expect(settle).to be_nil
    first.update(status: "paid")
    second = settle
    expect(second.cost).to eq(10.0)
    expect(second.content.fetch("usage_allocations").first).to include("from_amount" => "10000.0", "to_amount" => "20000.0")
  end

  it "accumulates fractional cents before rounding and carries them forward" do
    a = usage(5000.004)
    b = usage(5000.004)
    first = settle
    expect(first.cost).to eq(10.0)
    expect(project.reload.inference_billing_remainder).to eq(BigDecimal("0.000008"))
    first.update(status: "paid")
    a.update(amount: a.amount + BigDecimal("5000.996"))
    b.update(amount: b.amount + BigDecimal("5000.996"))
    second = settle
    expect(second.cost).to eq(10.0)
    expect(project.reload.inference_billing_remainder).to eq(BigDecimal("0.002"))
  end

  it "preserves monetary credits without granting a plan discount" do
    project.update(credit: 3, discount: 100)
    record = usage(10_000)
    expect(settle).to be_nil
    expect(project.reload.credit).to eq(3)
    expect(record.reload.inference_invoiced_amount).to eq(0)
    record.update(amount: 13_000)
    invoice = settle
    expect(invoice.content.to_h).to include("credit" => 3.0, "discount" => 0, "cost" => 10.0)
    expect(project.reload.credit).to eq(0)
  end

  it "records fully prepaid usage without asking for a card charge" do
    project.update(credit: 20)
    usage(10_000)
    invoice = settle
    expect(invoice.cost).to eq(0)
    expect(project.reload.credit).to eq(10)
  end

  it "issues month-end usage separately while carrying balances below one dollar" do
    record = usage(999, at: Time.utc(2026, 8, 31))
    expect(settle).to be_nil
    expect(record.reload.inference_invoiced_amount).to eq(0)
    record.update(amount: 1500)
    expect(settle.cost).to eq(1.5)
  end

  it "accumulates the unpaid balance after credits until the threshold" do
    project.update(credit: 9.5)
    record = usage(10_000)
    expect(settle).to be_nil
    record.update(amount: 10_500)
    expect(settle).to be_nil
    record.update(amount: 19_500)
    expect(settle.cost).to eq(10.0)
    expect(project.reload.credit).to eq(0)
  end

  it "collects a month-end balance below the usage threshold after credits" do
    project.update(credit: 9.5)
    record = usage(10_000, at: Time.utc(2026, 8, 31))
    expect(settle).to be_nil
    record.update(amount: 10_500)
    expect(settle.cost).to eq(1.0)
  end

  it "never allocates historical free records or includes paid records in normal invoices" do
    old = usage(10_000, paid: false)
    current = usage(10_000)
    invoice = settle
    expect(invoice.content["usage_allocations"].map { it["billing_record_id"] }).to eq([current.id])
    expect(old.reload.inference_invoiced_amount).to eq(0)
    standard = InvoiceGenerator.new(now - 3600, now, project_ids: [project.id]).active_billing_records
    expect(standard.map { it[:amount] }).to eq([old.amount])
  end

  it "rolls back invoice, credit and allocation if persistence fails" do
    project.update(credit: 2)
    record = usage(12_000)
    allow(Invoice).to receive(:create).and_raise("database failure")
    expect { settle }.to raise_error("database failure")
    expect(record.reload.inference_invoiced_amount).to eq(0)
    expect(project.reload.credit).to eq(2)
    expect(project.invoices_dataset.count).to eq(0)
  end

  it "blocks at the accrued threshold even before the worker creates an invoice" do
    usage(10_000)
    expect(described_class.payment_required?(project)).to be(true)
    project.update(credit: 1)
    expect(described_class.payment_required?(project)).to be(false)
  end

  it "keeps settled inference in monthly spend-limit accounting" do
    usage(10_000)
    expect(project.current_usage_cost(since: now - 3600)).to eq(10)
    settle.update(status: "paid")
    expect(project.current_usage_cost(since: now - 3600)).to eq(10)
    expect(project.current_invoice(since: now - 3600).cost).to eq(0)
  end

  it "rejects a tagged record with no price instead of silently making it free" do
    record = usage(10_000)
    record.update(resource_tags: {"paid_inference" => true, "unit_price" => "0"})
    expect { settle }.to raise_error(/no positive price/)
    expect(project.invoices_dataset.count).to eq(0)
  end

  it "uses the exact net amount for VAT" do
    billing_info = BillingInfo.create(stripe_id: "polar:test-inference-vat")
    project.update(billing_info_id: billing_info.id)
    allow_any_instance_of(BillingInfo).to receive(:billing_data).and_return({"country" => "NL", "email" => "billing@example.com"})
    usage(10_009)
    invoice = settle
    expect(invoice.content["vat_info"]).to include("amount" => 2.1, "eur_rate" => 0.9)
    expect(invoice.cost).to eq(12.1)
    expect(project.reload.inference_billing_remainder).to eq(BigDecimal("0.009"))
  end

  it "serializes concurrent allocators so one usage balance produces one invoice", :no_db_transaction do
    usage(10_000)
    project_id = project.id
    ready = Queue.new
    start = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ready << true
        start.pop
        described_class.settle!(project: Project[project_id], eur_rate: 0.9, now:)
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)
    expect(results.compact.length).to eq(1)
    expect(Invoice.where(project_id:).count).to eq(1)
  ensure
    threads&.each(&:join)
    if project_id
      Invoice.where(project_id:).delete(force: true)
      BillingRecord.where(project_id:).delete(force: true)
      Project.where(id: project_id).delete(force: true)
    end
  end
end
