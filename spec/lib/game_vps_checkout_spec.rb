# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GameVpsCheckout do
  def create_game_vps(project, name: "game-1")
    GameVps.create(
      project_id: project.id,
      name:,
      provider: "azure",
      status: "pending_payment",
      plan: "starter",
      location: "azure-eastus",
      image_alias: "windows-server-2022",
      rdp_username: "layerrail",
      rdp_password: "ComplexPass123!",
      cores: 2,
      ram_gib: 4,
      disk_gib: 128,
      monthly_price: BigDecimal("4.00")
    )
  end

  describe ".checkout_subscription_id" do
    it "reads the top-level subscription id returned by Polar checkout" do
      expect(described_class.checkout_subscription_id({"subscription_id" => "sub_123"})).to eq("sub_123")
    end

    it "falls back to nested subscription shapes" do
      expect(described_class.checkout_subscription_id({"subscription" => {"id" => "sub_nested"}})).to eq("sub_nested")
      expect(described_class.checkout_subscription_id({"order" => {"subscription_id" => "sub_order"}})).to eq("sub_order")
      expect(described_class.checkout_subscription_id({"order" => {"subscription" => {"id" => "sub_deep"}}})).to eq("sub_deep")
    end
  end

  describe ".expected_external_customer_ids" do
    it "accepts old project-scoped and new Game VPS-scoped Polar customers" do
      project = Project.create(name: "project-1")
      game_vps = create_game_vps(project)

      expect(described_class.expected_external_customer_ids([game_vps], project)).to eq([
        project.ubid,
        game_vps.polar_external_customer_id
      ])
    end
  end
end
