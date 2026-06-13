# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GameVps do
  it "keeps plan resources consistent with monthly price" do
    starter = described_class.plans.fetch("starter")
    community = described_class.plans.fetch("community")
    squad = described_class.plans.fetch("squad")
    growth = described_class.plans.fetch("growth")

    expect(community[:monthly_price].to_f).to be > starter[:monthly_price].to_f
    expect(community[:cores]).to eq(starter[:cores])
    expect(community[:ram_gib]).to be > starter[:ram_gib]
    expect(squad[:monthly_price].to_f).to be > community[:monthly_price].to_f
    expect(squad[:cores]).to be > community[:cores]
    expect(growth[:monthly_price].to_f).to be > squad[:monthly_price].to_f
    expect(growth[:ram_gib]).to be > squad[:ram_gib]
  end

  it "uses matching West Europe Azure SKU overrides for reordered starter plans" do
    expect(described_class.azure_size_for("community", "azure-westeurope")).to eq("Standard_D2ds_v6")
    expect(described_class.azure_size_for("squad", "azure-westeurope")).to eq("Standard_D4lds_v6")
  end
end
