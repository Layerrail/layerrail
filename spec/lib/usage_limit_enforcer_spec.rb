# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe UsageLimitEnforcer do
  let(:user) { Account.create(email: "owner@example.com") }
  let(:project) { Project.create(name: "enforced-project") }
  let(:usage_limit) { UsageLimit.create(project_id: project.id, user_id: user.id, limit: 100) }
  let(:vm) {
    Prog::Vm::Nexus.assemble("ssh-ed25519 test", project.id, name: "limited-vm").subject.tap do |resource|
      resource.strand.update(label: "wait")
    end
  }
  let(:billing_rate) { BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1") }

  before do
    vm
    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: billing_rate.fetch("id"),
      amount: vm.vcpus,
    )
  end

  it "does not suspend after a concurrent adjustment already resumed the limit" do
    expect(described_class.suspend!(usage_limit, only_if_suspended: true)).to be(false)

    expect(usage_limit.reload.suspended?).to be(false)
    expect(vm.reload.usage_limit_suspended_set?).to be(false)
    expect(BillingRecord.where(resource_id: vm.id).active.count).to eq(1)
  end

  it "idempotently stops running VMs and pauses ongoing billing" do
    described_class.suspend!(usage_limit)
    described_class.suspend!(usage_limit.reload)

    expect(vm.reload.usage_limit_suspended_set?).to be(true)
    expect(vm.stop_set?).to be(true)
    expect(usage_limit.reload.suspended?).to be(true)
    expect(BillingRecord.where(resource_id: vm.id).active.count).to eq(0)
    expect(UsageLimitBillingRecord.where(usage_limit_id: usage_limit.id).count).to eq(1)
  end

  it "starts only resources stopped by the limit and restores billing once" do
    described_class.suspend!(usage_limit)

    described_class.resume!(usage_limit.reload)

    expect(vm.reload.usage_limit_suspended_set?).to be(false)
    expect(vm.start_set?).to be(true)
    expect(BillingRecord.where(resource_id: vm.id).active.count).to eq(1)
    expect(UsageLimitBillingRecord.where(usage_limit_id: usage_limit.id).count).to eq(0)
  end

  it "does not mark an already stopped VM for automatic restart" do
    vm.strand.update(label: "stopped")
    vm.decr_stop

    described_class.suspend!(usage_limit)
    described_class.resume!(usage_limit.reload)

    expect(vm.reload.usage_limit_suspended_set?).to be(false)
    expect(vm.start_set?).to be(false)
  end
end