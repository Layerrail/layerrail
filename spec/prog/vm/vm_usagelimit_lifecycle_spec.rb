# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Vm, "usage-limit lifecycle" do
  {
    Prog::Vm::Azure::Nexus => "stop",
    Prog::Vm::Linode::Nexus => "stop",
    Prog::Vm::Metal::Nexus => "stopped",
    Prog::Vm::Aws::Nexus => "stop",
    Prog::Vm::Gcp::Nexus => "stop",
  }.each do |nexus_class, expected_label|
    it "routes #{nexus_class.name} into #{expected_label}" do
      prog_name = nexus_class.name.delete_prefix("Prog::")
      strand = Strand.new(prog: prog_name, label: "wait", stack: [{}])
      snapshot = instance_double(SemSnap)
      allow(snapshot).to receive(:set?).with(:usage_limit_suspended).and_return(true)
      nexus = nexus_class.new(strand, snapshot)

      expect { nexus.wait }.to hop(expected_label)
    end
  end
end