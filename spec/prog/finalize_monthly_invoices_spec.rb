# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::FinalizeMonthlyInvoices do
  let(:project_id) { SecureRandom.uuid }
  let(:strand) { Strand.create(prog: "FinalizeMonthlyInvoices", label: "finalize_project", stack: [{"month" => "2026-09-01", "project_id" => project_id}]) }
  let(:prog) { described_class.new(strand) }

  it "runs one project's monthly finalization after commit within the strand lease" do
    finalizer = instance_double(MonthlyInvoiceFinalizer)
    expect(DB).to receive(:after_commit).and_yield
    expect(MonthlyInvoiceFinalizer).to receive(:new).with(month: Date.new(2026, 9, 1), project_ids: [project_id]).and_return(finalizer)
    expect(Timeout).to receive(:timeout).with(75).and_yield
    expect(finalizer).to receive(:run)

    expect { prog.finalize_project }.to exit({"msg" => "project monthly invoice finalized"})
  end

  it "throttles recurring scans" do
    strand.update(label: "wait", stack: [{"next_scan_at" => (Time.now + 3600).utc.iso8601}])
    expect { prog.wait }.to nap(a_value_between(3599, 3600))
  end

  it "has a valid stable worker identifier" do
    expect(UBID.parse("stzzzzzzzz021gzzm0nth1y110").to_uuid).to be_a(String)
  end

  it "leaves project work to separate children instead of a single long callback" do
    finalizer = instance_double(MonthlyInvoiceFinalizer, candidate_project_ids: [project_id])
    expect(MonthlyInvoiceFinalizer).to receive(:new).with(month: Date.new(2026, 9, 1)).and_return(finalizer)
    expect(DB).not_to receive(:after_commit)
    expect(prog).to receive(:bud).with(described_class, {"month" => "2026-09-01", "project_id" => project_id}, "finalize_project")

    expect { prog.finalize }.to hop("wait_projects")
  end

  it "waits without donating its lease to slow child deliveries" do
    expect(prog).to receive(:reap).with(:finish, nap: 10)
    prog.wait_projects
    expect(prog).to receive(:reap).with(:wait, nap: 10)
    prog.wait_finalizations
  end
end
