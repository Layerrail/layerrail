# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::BackupPolicyNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "backup-limit-project") }
  let(:user) { Account.create(email: "backup-owner@example.com") }
  let(:vm) { Prog::Vm::Nexus.assemble("ssh-ed25519 test", project.id, name: "backup-vm").subject }
  let(:policy) { VmBackupPolicy.create(vm_id: vm.id, next_backup_at: Time.now) }
  let(:strand) { Strand.create_with_id(policy, prog: "Vm::BackupPolicyNexus", label: "wait", stack: [{"subject_id" => policy.id}]) }

  it "pauses scheduled backup work while the project is usage-limited" do
    UsageLimit.create(
      project_id: project.id,
      user_id: user.id,
      limit: 100,
      suspended_at: Time.now,
      suspended_revision: 1,
    )

    expect { nx.before_run }.to nap(5 * 60)
  end
end