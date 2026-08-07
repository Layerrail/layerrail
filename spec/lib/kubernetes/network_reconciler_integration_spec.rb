# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "open3"

RSpec.describe Kubernetes::NetworkReconciler, :no_db_transaction do
  it "persists pod-network repair work through a fresh semaphore snapshot" do
    strand = Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "wait")
    begin
      SemSnap.use(strand.id) { it.incr(:sync_pod_network) unless it.set?(:sync_pod_network) }

      expect(Semaphore.where(strand_id: strand.id, name: "sync_pod_network").count).to eq(1)
    ensure
      Semaphore.where(strand_id: strand.id).destroy
      strand.destroy
    end
  end

  it "carries pod-CIDR traffic between isolated Linux nodes over VXLAN" do
    skip "requires Linux network namespace privileges" unless RUBY_PLATFORM.include?("linux") && Process.uid.zero?

    suffix = Process.pid.to_s(16)
    left_ns = "lr-left-#{suffix}"
    right_ns = "lr-right-#{suffix}"
    underlay_ns = "lr-underlay-#{suffix}"
    bridge = "lrb#{suffix}"[0, 14]
    left_host = "lrhl#{suffix}"[0, 15]
    left_node = "lrnl#{suffix}"[0, 15]
    right_host = "lrhr#{suffix}"[0, 15]
    right_node = "lrnr#{suffix}"[0, 15]

    run = lambda do |command|
      output, error, status = Open3.capture3(command)
      fail "#{command}\n#{output}\n#{error}" unless status.success?
      output
    end

    begin
      run.call("ip netns add #{left_ns}")
      run.call("ip netns add #{right_ns}")
      run.call("ip netns add #{underlay_ns}")
      run.call("ip netns exec #{underlay_ns} ip link add #{bridge} type bridge")
      run.call("ip link add #{left_host} type veth peer name #{left_node}")
      run.call("ip link add #{right_host} type veth peer name #{right_node}")
      run.call("ip link set #{left_node} netns #{left_ns}")
      run.call("ip link set #{right_node} netns #{right_ns}")
      run.call("ip link set #{left_host} netns #{underlay_ns}; ip link set #{right_host} netns #{underlay_ns}")
      run.call("ip netns exec #{underlay_ns} ip link set #{bridge} up")
      [left_host, right_host].each { run.call("ip netns exec #{underlay_ns} ip link set #{it} master #{bridge}; ip netns exec #{underlay_ns} ip link set #{it} up") }
      run.call("ip netns exec #{left_ns} ip link set lo up; ip netns exec #{left_ns} ip link set #{left_node} name eth0; ip netns exec #{left_ns} ip addr add 10.138.1.1/16 dev eth0; ip netns exec #{left_ns} ip -6 addr add fd00::1/64 dev eth0; ip netns exec #{left_ns} ip link set eth0 up")
      run.call("ip netns exec #{right_ns} ip link set lo up; ip netns exec #{right_ns} ip link set #{right_node} name eth0; ip netns exec #{right_ns} ip addr add 10.138.2.1/16 dev eth0; ip netns exec #{right_ns} ip -6 addr add fd00::1:0:0:1/64 dev eth0; ip netns exec #{right_ns} ip link set eth0 up")
      run.call("ip netns exec #{left_ns} ip addr add 10.138.1.2/32 dev lo")
      run.call("ip netns exec #{right_ns} ip addr add 10.138.2.2/32 dev lo")
      run.call("ip netns exec #{left_ns} ping -c 1 -W 1 10.138.2.1")

      provider_location = Struct.new(:linode?, :azure?).new(false, true)
      left_nic = Struct.new(:private_ipv4, :private_ipv6).new(NetAddr::IPv4Net.parse("10.138.1.0/24"), NetAddr::IPv6Net.parse("fd00::/80"))
      right_nic = Struct.new(:private_ipv4, :private_ipv6).new(NetAddr::IPv4Net.parse("10.138.2.0/24"), NetAddr::IPv6Net.parse("fd00::1:0:0:0/80"))
      left_vm = Struct.new(:location, :nics, :ip6).new(provider_location, [left_nic], NetAddr.parse_ip("fd00::1"))
      right_vm = Struct.new(:location, :nics, :ip6).new(provider_location, [right_nic], NetAddr.parse_ip("fd00::1:0:0:1"))
      left = Struct.new(:id, :vm).new("left", left_vm)
      right = Struct.new(:id, :vm).new("right", right_vm)
      cluster = Struct.new(:id).new("cluster-integration")
      reconciler = described_class.new(cluster)
      addresses = {left.id => "10.138.1.1", right.id => "10.138.2.1"}
      left_script = reconciler.route_script(left, [left, right], addresses)
      right_script = reconciler.route_script(right, [left, right], addresses)
      run.call("ip netns exec #{left_ns} sh -c #{Shellwords.escape(left_script)}")
      run.call("ip netns exec #{right_ns} sh -c #{Shellwords.escape(right_script)}")
      expect(run.call("ip netns exec #{left_ns} ip route get 10.138.2.1")).to include("dev eth0")
      expect(run.call("ip netns exec #{right_ns} ip route get 10.138.1.1")).to include("dev eth0")
      expect(run.call("ip netns exec #{left_ns} ip -6 route get fd00::1:0:0:1")).to include("dev eth0")
      expect(run.call("ip netns exec #{right_ns} ip -6 route get fd00::1")).to include("dev eth0")
      run.call("ip netns exec #{left_ns} ping -c 1 -W 1 #{reconciler.vxlan_topology([left, right]).fetch(right.id).fetch(:tunnel_ipv4)}")
      run.call("ip netns exec #{left_ns} ping -c 2 -W 1 10.138.2.2")
      run.call("ip netns exec #{right_ns} ping -c 2 -W 1 10.138.1.2")
    ensure
      system("ip netns del #{left_ns} 2>/dev/null")
      system("ip netns del #{right_ns} 2>/dev/null")
      system("ip netns del #{underlay_ns} 2>/dev/null")
    end
  end
end
