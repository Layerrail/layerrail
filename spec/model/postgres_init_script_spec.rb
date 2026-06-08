# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PostgresInitScript do
  it "implements a max length validation on the init_script column" do
    init_script = described_class.new(init_script: "a" * 20001)
    expect(init_script.valid?).to be false
    init_script.init_script = "a" * 20000
    expect(init_script.valid?).to be true
  end
end
