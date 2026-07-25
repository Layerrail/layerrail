# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GameVps do
  it "uses the reduced price ladder and fixed Windows storage baseline" do
    expect(described_class.plans.transform_values { it[:monthly_price] }).to eq(
      "starter" => "3.00",
      "community" => "5.00",
      "squad" => "8.00",
      "growth" => "16.00",
      "serious" => "40.00",
      "arena" => "75.00"
    )
    expect(described_class.plans.values.map { it[:disk_gib] }.uniq).to eq([128])
  end

  it "builds the Bachs catalog update from the plan source of truth" do
    expect(described_class.bachs_product_update_payload("growth")).to eq(
      name: "LayerRail Game VPS - Growth",
      description: "Growing roleplay or survival community. 4 vCPU, 16 GB RAM, 128 GB Windows SSD.",
      price: {price_type: "fixed", currency: "USD", amount: "16.00"}
    )
  end

  it "builds the Polar catalog update from the plan source of truth" do
    expect(described_class.polar_product_update_payload("growth")).to eq(
      name: "LayerRail Game VPS - Growth",
      description: "Growing roleplay or survival community. 4 vCPU, 16 GB RAM, 128 GB Windows SSD.",
      prices: [{amount_type: "fixed", price_currency: "usd", price_amount: 1600}],
      metadata: {
        layerrail_role: "game_vps_plan",
        layerrail_plan: "growth",
        layerrail_amount_cents: 1600,
        layerrail_provider: "azure"
      }
    )
  end

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
