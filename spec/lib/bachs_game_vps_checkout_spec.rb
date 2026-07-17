# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BachsGameVpsCheckout do
  let(:project) { Project.create(name: "project-1") }

  def create_game_vps(**values)
    checkout_values = values.slice(:checkout_id, :polar_subscription_id, :paid_until)
    game_vps = GameVps.create({
      project_id: project.id,
      name: "game-1",
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
    }.merge(values.except(*checkout_values.keys)))
    GameVps.where(id: game_vps.id).update(checkout_values) unless checkout_values.empty?
    game_vps.refresh
  end

  def paid_checkout(game_vps, subscription_id: "sub_game_1")
    {
      "checkout_id" => game_vps.values[:checkout_id],
      "status" => "COMPLETED",
      "payment_status" => "succeeded",
      "amount" => "4.00",
      "currency" => "USD",
      "metadata" => {"kind" => "game_vps_checkout", "project_id" => project.ubid},
      "charge" => {"subscription_id" => subscription_id}
    }
  end

  def active_subscription(period_end: "2026-08-17T12:00:00Z")
    {"id" => "sub_game_1", "status" => "active", "current_period_end" => period_end}
  end

  it "activates a paid recurring checkout using the Bachs billing period" do
    game_vps = create_game_vps(checkout_id: "chk_game_1")
    period_end = Time.iso8601("2026-08-17T12:00:00Z")
    allow(BachsClient).to receive(:get_checkout).with("chk_game_1").and_return(paid_checkout(game_vps))
    allow(BachsClient).to receive(:get_subscription).with("sub_game_1").and_return(active_subscription)
    allow(Prog::GameVpsNexus).to receive(:assemble)

    expect(described_class.reconcile!("chk_game_1", project:)).to eq(status: "provisioning", count: 1)

    game_vps.refresh
    expect(game_vps.status).to eq("creating")
    expect(game_vps.polar_subscription_id).to eq("sub_game_1")
    expect(game_vps.values[:paid_until]).to eq(period_end)
    expect(Prog::GameVpsNexus).to have_received(:assemble).with(game_vps)
  end

  it "returns the prior result without calling Bachs again" do
    create_game_vps(checkout_id: "chk_game_1", status: "creating", polar_subscription_id: "sub_game_1")
    expect(BachsClient).not_to receive(:get_checkout)

    expect(described_class.reconcile!("chk_game_1", project:)).to eq(
      status: "already_processed",
      count: 1,
      states: ["creating"]
    )
  end

  it "does not consume invoice collection events" do
    event = {
      "type" => "collection.succeeded",
      "data" => {
        "checkout_id" => "chk_invoice_1",
        "metadata" => {"kind" => "invoice_payment", "invoice" => "1v_invoice"}
      }
    }
    expect(BachsClient).not_to receive(:get_checkout)

    expect(described_class.reconcile_event!(event)).to eq(status: "ignored")
  end

  it "extends a Game VPS from active subscription events without regressing its paid period" do
    existing_period_end = Time.iso8601("2026-08-17T12:00:00Z")
    game_vps = create_game_vps(
      status: "running",
      checkout_id: "chk_game_1",
      polar_subscription_id: "sub_game_1",
      paid_until: existing_period_end
    )
    event = {"type" => "invoice.paid", "data" => {"subscription" => {"id" => "sub_game_1"}, "status" => "paid"}}
    allow(BachsClient).to receive(:get_subscription).with("sub_game_1").and_return(active_subscription(period_end: "2026-09-17T12:00:00Z"))

    expect(described_class.reconcile_event!(event)).to eq(status: "renewed", count: 1)
    expect(game_vps.refresh.values[:paid_until]).to eq(Time.iso8601("2026-09-17T12:00:00Z"))

    subscription_event = {"type" => "customer.subscription.updated", "data" => {"subscription_id" => "sub_game_1", "status" => "active"}}
    allow(BachsClient).to receive(:get_subscription).with("sub_game_1").and_return(active_subscription(period_end: "2026-07-17T12:00:00Z"))
    expect(described_class.reconcile_event!(subscription_event)).to eq(status: "renewed", count: 1)
    expect(game_vps.refresh.values[:paid_until]).to eq(Time.iso8601("2026-09-17T12:00:00Z"))
  end
end
