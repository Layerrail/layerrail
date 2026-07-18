# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "game vps" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  def create_game_vps(project, name:, status:, primary_ip: nil)
    GameVps.create(
      project_id: project.id,
      name:,
      provider: "azure",
      status:,
      plan: "starter",
      location: "azure-eastus",
      image_alias: "windows-server-2022",
      primary_ip:,
      rdp_username: "layerrail",
      rdp_password: "ComplexPass123!",
      cores: 2,
      ram_gib: 4,
      disk_gib: 128,
      monthly_price: BigDecimal("4.00")
    )
  end

  before do
    allow(Config).to receive(:game_vps_enabled).and_return(true)
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    it "redirects the details page to the overview tab" do
      game_vps = create_game_vps(project, name: "paid-game", status: "running", primary_ip: "192.0.2.10")

      visit "#{project.path}#{game_vps.path}"

      expect(page).to have_current_path("#{project.path}#{game_vps.path}/overview")
      expect(page).to have_content("paid-game")
      expect(page).to have_content("192.0.2.10")
      expect(page.status_code).to eq(200)
    end

    it "shows pending payment reservations so checkout can be resumed" do
      create_game_vps(project, name: "paid-game", status: "running")
      create_game_vps(project, name: "payment-waiting", status: "pending_payment")

      visit "#{project.path}/game-vps"

      expect(page).to have_content("paid-game")
      expect(page).to have_content("payment-waiting")

      click_link "payment-waiting"
      expect(page).to have_button("Continue checkout")
    end
  end
end
