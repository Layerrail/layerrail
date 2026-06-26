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
end
