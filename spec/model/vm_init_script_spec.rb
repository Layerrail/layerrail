# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmInitScript do
  it "implements a max length validation on the init_script column" do
    vm = described_class.new(init_script: "a" * 20001)
    expect(vm.valid?).to be false
    vm.init_script = "a" * 20000
    expect(vm.valid?).to be true
  end
end
