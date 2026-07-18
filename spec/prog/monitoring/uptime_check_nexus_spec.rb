# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Monitoring::UptimeCheckNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "uptime-limit-project") }
  let(:user) { Account.create(email: "uptime-owner@example.com") }
  let(:uptime_check) do
    UptimeCheck.create(
      project_id: project.id,
      name: "limited-check",
      target_url: "https://example.com/health",
      interval_seconds: 60,
    )
  end
  let(:strand) { Strand.create_with_id(uptime_check, prog: "Monitoring::UptimeCheckNexus", label: "wait", stack: [{"subject_id" => uptime_check.id}]) }

  it "pauses checks while the project is usage-limited" do
    UsageLimit.create(
      project_id: project.id,
      user_id: user.id,
      limit: 100,
      suspended_at: Time.now,
      suspended_revision: 1,
    )
    expect(uptime_check).not_to receive(:run_check!)

    expect { nx.wait }.to nap(60)
    expect(uptime_check.reload.state).to eq("paused")
  end
end