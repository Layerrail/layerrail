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

    it "reconciles UUID checkout returns through Bachs" do
      checkout_id = "808e9dc2-2af3-4a8b-9fc9-956f34fac3c2"
      expect(BachsGameVpsCheckout).to receive(:reconcile!).with(checkout_id, project:).and_return(status: "provisioning", count: 1)
      expect(GameVpsCheckout).not_to receive(:reconcile!)

      visit "#{project.path}/game-vps/success/bachs?checkout_id=#{checkout_id}"

      expect(page).to have_current_path("#{project.path}/game-vps")
      expect(page).to have_flash_notice("Game VPS payment received. Provisioning started.")
    end

    it "updates the Bachs plan price before starting checkout" do
      checkout_id = "808e9dc2-2af3-4a8b-9fc9-956f34fac3c2"
      allow(Config).to receive(:game_vps_provider).and_return("azure")
      allow(Config).to receive(:game_vps_checkout_provider).and_return("bachs")
      allow(Config).to receive(:bachs_game_vps_product_ids).and_return(JSON.generate("growth" => "prod_growth"))
      allow(AzureClient).to receive(:enabled?).and_return(true)
      allow(BachsClient).to receive(:enabled?).and_return(true)
      expect(BachsClient).to receive(:update_product)
        .with("prod_growth", GameVps.bachs_product_update_payload("growth"))
        .ordered
        .and_return("id" => "prod_growth")
      expect(BachsClient).to receive(:create_checkout)
        .with(
          hash_including(
            product_cart: [{product_id: "prod_growth", quantity: 1}],
            metadata: hash_including(plan: "growth", product_id: "prod_growth", amount_cents: 1600)
          ),
          idempotency_key: kind_of(String)
        )
        .ordered
        .and_return("checkout_id" => checkout_id, "checkout_url" => "https://checkout.bachs.io/#{checkout_id}")

      visit "#{project.path}/game-vps/create"
      csrf_token = find("form[action='#{project.path}/game-vps'] input[name='_csrf']", visible: false).value
      page.driver.post "#{project.path}/game-vps", {
        _csrf: csrf_token,
        name: "growth-server",
        plan: "growth",
        location: "azure-eastus",
        image_alias: "windows-server-2022",
        rdp_username: "layerrail",
        rdp_password: "ComplexPass123!"
      }

      expect(page.status_code).to eq(303)
      expect(page.response_headers["Location"]).to eq("https://checkout.bachs.io/#{checkout_id}")
      game_vps = project.game_vpses_dataset.first(name: "growth-server")
      expect(game_vps).to have_attributes(
        disk_gib: 128,
        monthly_price: BigDecimal("16.00")
      )
      expect(game_vps.values[:checkout_id]).to eq(checkout_id)
    end
  end
end
