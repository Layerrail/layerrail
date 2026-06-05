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

  describe "#start" do
    it "always adds control plane SSH rules to the Linode firewall" do
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["203.0.113.10/32", "2001:db8::/64"])

      expect(client).to receive(:create_firewall) do |label:, rules:, tags:|
        expect(label).to start_with("lr-")
        expect(tags).to include("LayerRail", private_subnet.project.ubid)
        expect(rules["inbound_policy"]).to eq("DROP")
        expect(rules["outbound_policy"]).to eq("ACCEPT")
        expect(rules["inbound"]).to include(
          {
            "action" => "ACCEPT",
            "protocol" => "TCP",
            "ports" => "22",
            "addresses" => {"ipv4" => ["203.0.113.10/32"], "ipv6" => []},
            "label" => "lr-control-plane-ssh-0",
          },
          {
            "action" => "ACCEPT",
            "protocol" => "TCP",
            "ports" => "22",
            "addresses" => {"ipv4" => [], "ipv6" => ["2001:db8::/64"]},
            "label" => "lr-control-plane-ssh-1",
          },
        )
        {"id" => 123}
      end

      expect { nx.start }.to hop("wait")
    end

    it "does not duplicate SSH rules already present on the subnet firewall" do
      allow(Config).to receive(:control_plane_outbound_cidrs).and_return(["0.0.0.0/0", "::/0"])

      expect(client).to receive(:create_firewall) do |label:, rules:, tags:|
        expect(rules["inbound"].filter { it["ports"] == "22" }.count).to eq(2)
        expect(rules["inbound"].none? { it["label"].start_with?("lr-control-plane-ssh") }).to be true
        {"id" => 123}
      end

      expect { nx.start }.to hop("wait")
    end
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
