# frozen_string_literal: true

require_relative "../../model/spec_helper"

require "open3"

RSpec.describe Kubernetes::NetworkReconciler do
  subject(:reconciler) { described_class.new(cluster) }

  let(:cluster) { instance_double(KubernetesCluster, id: "cluster-test") }
  let(:client) { instance_double(Kubernetes::Client) }
  let(:first_sshable) { Sshable.new }
  let(:second_sshable) { Sshable.new }
  let(:first_nic) { instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.138.1.0/24"), private_ipv6: NetAddr::IPv6Net.parse("fd40::/80")) }
  let(:second_nic) { instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.138.2.0/24"), private_ipv6: NetAddr::IPv6Net.parse("fd40:0:0:1::/80")) }
  let(:linode_location) { instance_double(Location, linode?: true, azure?: false) }
  let(:azure_location) { instance_double(Location, linode?: false, azure?: true) }
  let(:first_vm) do
    instance_double(
      Vm,
      location: linode_location,
      nics: [first_nic],
      private_ipv4_string: "10.138.1.1",
      ip6: NetAddr.parse_ip("fd40::1"),
    )
  end
  let(:second_vm) do
    instance_double(
      Vm,
      location: azure_location,
      nics: [second_nic],
      private_ipv4_string: "10.138.2.1",
      ip6: NetAddr.parse_ip("fd40:0:0:1::1"),
    )
  end
  let(:first_node) { instance_double(KubernetesNode, id: "first", name: "first-node", vm: first_vm, sshable: first_sshable) }
  let(:second_node) { instance_double(KubernetesNode, id: "second", name: "second-node", vm: second_vm, sshable: second_sshable) }

  before do
    allow(cluster).to receive_messages(all_functional_nodes: [first_node, second_node], client:)
    allow(first_sshable).to receive(:_cmd).with(described_class::LINODE_PRIVATE_IPV4_COMMAND, log: false).and_return("192.168.140.10\n")
  end

  it "installs and validates the custom CNI on every node" do
    # Multiple ordered commands per SSH endpoint make an aggregate matcher less clear here.
    # rubocop:disable RSpec/IteratedExpectation
    [first_sshable, second_sshable].each do |sshable|
      expect(sshable).to receive(:_cmd).with("sudo install -d -m 0755 /opt/cni/bin /etc/cni/net.d").ordered
      expect(sshable).to receive(:_cmd).with(
        "sudo tee /opt/cni/bin/ubicni > /dev/null && sudo chmod 0755 /opt/cni/bin/ubicni",
        stdin: described_class::CNI_WRAPPER,
        log: false,
      ).ordered
      expect(sshable).to receive(:_cmd).with(
        "sudo tee /etc/cni/net.d/ubicni-config.json > /dev/null",
        stdin: include('"type": "ubicni"'),
        log: false,
      ).ordered
      expect(sshable).to receive(:_cmd).with(
        "sudo tee /etc/sysctl.d/99-layerrail-kubernetes-network.conf > /dev/null && sudo sysctl --system > /dev/null",
        stdin: described_class::SYSCTL_CONFIG,
        log: false,
      ).ordered
      expect(sshable).to receive(:_cmd).with(
        "sudo tee /usr/local/sbin/layerrail-k8s-routes > /dev/null && sudo chmod 0755 /usr/local/sbin/layerrail-k8s-routes",
        stdin: include("ip route replace"),
        log: false,
      ).ordered
      expect(sshable).to receive(:_cmd).with(
        "sudo tee /etc/systemd/system/layerrail-k8s-routes.service > /dev/null && sudo systemctl daemon-reload && sudo systemctl enable --now layerrail-k8s-routes.service && sudo systemctl restart layerrail-k8s-routes.service",
        stdin: described_class::ROUTE_SERVICE,
        log: false,
      ).ordered
      expect(sshable).to receive(:_cmd).with(
        "sudo test -x /opt/cni/bin/ubicni && test -x /home/ubi/kubernetes/bin/ubicni && sudo ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' /etc/cni/net.d/ubicni-config.json && test \"$(sysctl -n net.ipv4.ip_forward)\" = 1",
        log: false,
      ).ordered
    end
    # rubocop:enable RSpec/IteratedExpectation
    expect(client).to receive(:set_node_addresses).with(
      "first-node",
      include({"type" => "InternalIP", "address" => "192.168.140.10"}),
    )
    expect(client).to receive(:set_node_addresses).with(
      "second-node",
      include({"type" => "InternalIP", "address" => "10.138.2.1"}),
    )

    reconciler.reconcile
  end

  it "encapsulates every peer pod CIDR through a deterministic VXLAN mesh" do
    addresses = {first_node.id => "192.168.140.10", second_node.id => "10.138.2.1"}
    topology = reconciler.vxlan_topology([first_node, second_node])

    expect(reconciler.route_script(first_node, [first_node, second_node], addresses)).to include(
      "type vxlan id #{reconciler.vxlan_id} local 192.168.140.10 dstport 8472 nolearning",
      "bridge fdb append 00:00:00:00:00:00 dev layerrail-vxlan dst 10.138.2.1",
      "ip route replace 10.138.2.0/24 via #{topology.fetch(second_node.id).fetch(:tunnel_ipv4)} dev layerrail-vxlan onlink proto 196",
    )
    expect(reconciler.route_script(second_node, [first_node, second_node], addresses)).to include(
      "ip route replace 10.138.1.0/24 via #{topology.fetch(first_node.id).fetch(:tunnel_ipv4)} dev layerrail-vxlan onlink proto 196",
    )
    expect(reconciler.route_script(first_node, [first_node, second_node], addresses)).to include("ip route flush proto 196")
  end

  it "keeps peer node underlay addresses off overlapping pod CIDR routes" do
    addresses = {first_node.id => "10.138.1.1", second_node.id => "10.138.2.1"}

    first_script = reconciler.route_script(first_node, [first_node, second_node], addresses)
    second_script = reconciler.route_script(second_node, [first_node, second_node], addresses)

    expect(first_script).to include(
      "preserve_underlay_route -4 10.138.2.1 32",
      "preserve_underlay_route -6 fd40:0:0:1::1 128",
      'ip route get 10.138.2.1 | grep -Fv "dev layerrail-vxlan" > /dev/null',
      'ip -6 route get fd40:0:0:1::1 | grep -Fv "dev layerrail-vxlan" > /dev/null',
    )
    expect(second_script).to include(
      "preserve_underlay_route -4 10.138.1.1 32",
      "preserve_underlay_route -6 fd40::1 128",
      'ip route get 10.138.1.1 | grep -Fv "dev layerrail-vxlan" > /dev/null',
      'ip -6 route get fd40::1 | grep -Fv "dev layerrail-vxlan" > /dev/null',
    )
    expect(first_script.index("preserve_underlay_route -4 10.138.2.1 32")).to be < first_script.index("ip route replace 10.138.2.0/24")
  end

  it "uses stable, cluster-scoped tunnel identities" do
    first = reconciler.vxlan_topology([first_node, second_node])
    second = reconciler.vxlan_topology([second_node, first_node])

    expect(second).to eq(first)
    expect(first.values.map { it[:mac] }.uniq.length).to eq(2)
    expect(first.values.map { it[:tunnel_ipv4] }.uniq.length).to eq(2)

    remaining = reconciler.vxlan_topology([second_node])
    expect(remaining.fetch(second_node.id)).to eq(first.fetch(second_node.id))
  end

  it "does nothing for a cluster without active nodes" do
    allow(cluster).to receive(:all_functional_nodes).and_return([])
    expect(cluster).not_to receive(:client)

    reconciler.reconcile
  end
end
