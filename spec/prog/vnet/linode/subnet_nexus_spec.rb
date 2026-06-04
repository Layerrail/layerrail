# frozen_string_literal: true

RSpec.describe Prog::Vnet::Linode::SubnetNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "default") }
  let(:location) { Option.locations.find { it.provider == "linode" } }
  let(:private_subnet) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "linode-ps", location_id: location.id).subject
  }
  let(:st) { private_subnet.strand }
  let(:client) { instance_double(LinodeClient) }

  before do
    allow(LinodeClient).to receive(:new).and_return(client)
    allow(client).to receive(:delete_firewall)
  end

  describe "#destroy" do
    it "waits for load balancers to be destroyed before deleting the subnet" do
      PrivateSubnetLinodeResource.create_with_id(private_subnet, firewall_id: "123")
      load_balancer = Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: "lb", src_port: 80, dst_port: 8080).subject

      expect { nx.destroy }.to nap(1)

      expect(load_balancer.reload.destroy_set?).to be true
      expect(private_subnet).to exist
    end
  end
end
