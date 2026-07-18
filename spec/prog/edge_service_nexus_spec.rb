# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::EdgeServiceNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "edge-limit-project") }
  let(:edge_service) do
    EdgeService.create(
      project_id: project.id,
      name: "limited-edge",
      hostname: "limited-edge.example.com",
      origin_url: "https://origin.example.com",
      cache_mode: "standard",
      tls_mode: "strict",
      state: "ready",
    )
  end
  let(:strand) { Strand.create_with_id(edge_service, prog: "EdgeServiceNexus", label: "usage_limit_suspend", stack: [{"subject_id" => edge_service.id}]) }

  before do
    allow(CloudflareDnsClient).to receive(:configured?).and_return(false)
  end

  it "holds in-flight provisioning while usage-limited" do
    edge_service.update(state: "creating")
    strand.update(label: "start")
    edge_service.incr_usage_limit_suspended
    fresh_nx = described_class.new(strand.reload)

    expect { fresh_nx.before_run }.to nap(5 * 60)
  end

  it "removes routing while preserving the edge service" do
    edge_service.incr_usage_limit_suspended

    expect { nx.usage_limit_suspend }.to hop("usage_limit_suspended")

    expect(edge_service.reload.state).to eq("suspended")
    expect(edge_service.exists?).to be(true)
  end

  it "restores routing after the limit is adjusted" do
    edge_service.update(state: "suspended")
    edge_service.incr_usage_limit_resume
    allow(edge_service).to receive(:ensure_billing_record!)

    expect { nx.usage_limit_resume }.to hop("wait")

    expect(edge_service.reload.state).to eq("ready")
    expect(Semaphore.where(strand_id: edge_service.id, name: "usage_limit_resume")).to be_empty
  end
end