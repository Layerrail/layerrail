# frozen_string_literal: true

RSpec.describe Prog::GameVpsNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "game-vps-project") }
  let(:game_vps) {
    GameVps.create(
      project_id: project.id,
      name: "game-1",
      provider: "azure",
      status: "creating",
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
  }
  let(:strand) { Strand.create_with_id(game_vps, prog: "GameVpsNexus", label: "start_azure") }
  let(:client) { instance_double(AzureClient) }

  before do
    allow(AzureClient).to receive(:new).and_return(client)
    allow(client).to receive(:create_resource_group)
    allow(client).to receive(:create_game_network_security_group).and_return({"id" => "nsg-id"})
    allow(client).to receive(:create_virtual_network).and_return({"properties" => {"subnets" => [{"id" => "subnet-id"}]}})
    allow(client).to receive(:create_public_ip).and_return({"id" => "public-ip-id"})
  end

  it "retries Azure subnet convergence errors instead of failing the game VPS" do
    allow(client).to receive(:create_network_interface).and_raise(
      AzureAPIError.new(429, '{"error":{"code":"RetryableError","details":[{"code":"ReferencedResourceNotProvisioned","message":"subnet is in Updating state"}]}}')
    )

    expect { nx.start_azure }.to nap(30)
    expect(game_vps.reload.status).to eq("creating")
    expect(game_vps.failure_message).to be_nil
  end

  it "fails non-retryable Azure create errors" do
    allow(client).to receive(:create_network_interface).and_raise(AzureAPIError.new(400, "InvalidParameter"))

    expect { nx.start_azure }.to exit({"msg" => "game vps failed"})
    expect(game_vps.reload.status).to eq("failed")
    expect(game_vps.failure_message).to include("InvalidParameter")
  end

  it "redirects a provisioned server into usage-limit suspension" do
    game_vps.update(server_id: "game-vm", datacenter_id: "game-rg", status: "running")
    strand.update(label: "wait")
    game_vps.incr_usage_limit_suspended

    expect { nx.before_run }.to hop("usage_limit_suspend")
  end

  it "holds paid provisioning until a project usage limit is adjusted" do
    user = Account.create(email: "limit-owner@example.com")
    UsageLimit.create(
      project_id: project.id,
      user_id: user.id,
      limit: 100,
      suspended_at: Time.now,
      suspended_revision: 1,
    )

    expect { nx.before_run }.to nap(5 * 60)
    expect(nx.usage_limit_suspended_set?).to be(true)
    expect(game_vps.reload.status).to eq("creating")
    expect(game_vps.server_id).to be_nil
  end

  it "deallocates and later starts an Azure Game VPS" do
    game_vps.update(server_id: "game-vm", datacenter_id: "game-rg", status: "running")
    game_vps.incr_usage_limit_suspended
    expect(client).to receive(:shutdown_virtual_machine)

    expect { nx.usage_limit_suspend }.to hop("wait_usage_limit_suspended")
    expect(game_vps.reload.status).to eq("stopping")

    allow(client).to receive(:get_virtual_machine).and_return({"properties" => {"instanceView" => {"statuses" => [{"code" => "PowerState/deallocated"}]}}})
    expect { nx.wait_usage_limit_suspended }.to hop("usage_limit_suspended")
    expect(game_vps.reload.status).to eq("stopped")

    game_vps.decr_usage_limit_suspended
    game_vps.incr_usage_limit_resume
    expect(client).to receive(:power_on_virtual_machine)
    expect { nx.usage_limit_resume }.to hop("wait_usage_limit_resumed")
    expect(game_vps.reload.status).to eq("starting")
  end
end
