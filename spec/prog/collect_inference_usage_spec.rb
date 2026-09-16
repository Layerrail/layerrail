# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CollectInferenceUsage do
  let(:project) { Project.create(name: "usage-worker") }
  let(:strand) { Strand.create(prog: "CollectInferenceUsage", label: "collect", stack: [{"project_id" => project.id}]) }
  let(:prog) { described_class.new(strand) }

  it "collects existing usage invoices without fetching fresh billing or exchange rates" do
    expect(Clog).not_to receive(:emit)
    invoice = Invoice.create(project_id: project.id, billing_kind: "inference_usage", invoice_number: "AI-worker",
      begin_time: Time.now - 3600, end_time: Time.now, content: {"cost" => 10})
    expect(InferenceUsageBilling).not_to receive(:settle!)
    allow(DB).to receive(:after_commit).and_yield
    expect(InferenceUsageCollection).to receive(:collect!).with(have_attributes(id: invoice.id))
    expect { prog.collect }.to exit({"msg" => "inference usage collected"})
  end

  it "leaves failed collection available for the next scan" do
    expect(InferenceUsageBilling).to receive(:settle!).and_raise("temporary outage")
    expect { prog.collect }.to exit({"msg" => "inference usage collection will retry"})
  end

  it "throttles empty scans" do
    strand.update(label: "wait", stack: [{"next_scan_at" => (Time.now + 30).utc.iso8601}])
    expect { prog.wait }.to nap(a_value_between(29, 30))
  end

  it "commits invoice and exact checkout request before contacting Bachs", :no_db_transaction do
    billing_info = BillingInfo.create(stripe_id: "polar:usage-boundary-test")
    project.update(billing_info_id: billing_info.id)
    project_id = project.id
    worker_id = strand.id
    allow_any_instance_of(BillingInfo).to receive(:billing_data).and_return({"email" => "billing@example.com", "name" => "Customer", "country" => "US"})
    allow_any_instance_of(Invoice).to receive(:send_payment_due_email)
    allow(BachsClient).to receive(:invoice_checkout_enabled?).and_return(true)
    rate = BillingRate.from_resource_type("InferenceTokens").find { it["unit_price"].positive? }
    BillingRecord.create(project_id:, resource_id: project_id, resource_name: "token usage", billing_rate_id: rate.fetch("id"),
      amount: 10_000, span: Sequel.pg_range((Time.now - 3600)...Time.now), resource_tags: {paid_inference: true, unit_price: "0.001"})
    expect(BachsClient).to receive(:create_checkout) do |payload, idempotency_key:|
      committed = Thread.new do
        DB[:invoice].where(project_id:, billing_kind: "inference_usage").first
      end.value
      expect(committed[:content]["cost"]).to eq(10)
      state = committed[:content].fetch("bachs_checkout")
      expect(state["status"]).to eq("creating")
      expect(state["idempotency_key"]).to eq(idempotency_key)
      expect(JSON.parse(state["request_body"], symbolize_names: true)).to eq(payload)
      {"checkout_id" => "chk_boundary", "checkout_url" => "https://checkout.bachs.io/c/chk_boundary", "expires_at" => (Time.now + 3600).utc.iso8601}
    end
    DB.transaction do
      expect { prog.collect }.to exit({"msg" => "inference usage collected"})
      expect(Invoice.where(project_id:).first.content["bachs_checkout"]).to be_nil
    end
    expect(Invoice.where(project_id:).first.content["bachs_checkout"]["status"]).to eq("open")
  ensure
    if project_id
      Invoice.where(project_id:).delete(force: true)
      BillingRecord.where(project_id:).delete(force: true)
      Strand.where(id: worker_id).delete(force: true) if worker_id
      Project.where(id: project_id).delete(force: true)
      BillingInfo.where(id: billing_info.id).delete(force: true) if billing_info
    end
  end
end
