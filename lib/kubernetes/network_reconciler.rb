# frozen_string_literal: true

require "digest"
require "ipaddr"

class Kubernetes::NetworkReconciler
  # ubicni is a kubelet-invoked CNI binary, not a DaemonSet. The systemd unit
  # below persists its cross-node VXLAN routes across reboots. Each cluster is
  # isolated by a deterministic VNI and stable per-node tunnel identities.
  CNI_CONFIG_PATH = "/etc/cni/net.d/ubicni-config.json"
  CNI_BINARY_PATH = "/opt/cni/bin/ubicni"
  ROUTE_SCRIPT_PATH = "/usr/local/sbin/layerrail-k8s-routes"
  ROUTE_SERVICE_PATH = "/etc/systemd/system/layerrail-k8s-routes.service"
  SYSCTL_PATH = "/etc/sysctl.d/99-layerrail-kubernetes-network.conf"
  VXLAN_DEVICE = "layerrail-vxlan"
  VXLAN_PORT = 8472
  ROUTE_PROTOCOL = 196
  ROUTE_SERVICE = <<~UNIT.freeze
    [Unit]
    Description=LayerRail Kubernetes pod routes
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=#{ROUTE_SCRIPT_PATH}
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
  UNIT
  SYSCTL_CONFIG = <<~SYSCTL
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 1
    net.ipv6.conf.default.forwarding = 1
  SYSCTL
  CNI_WRAPPER = <<~SH
    #!/bin/sh
    set -eu
    cd /home/ubi
    test -x ./kubernetes/bin/ubicni
    exec ./kubernetes/bin/ubicni
  SH
  LINODE_PRIVATE_IPV4_COMMAND = <<~'SH'.tr("\n", " ").freeze
    ips=$(ip -4 -o addr show dev eth0 scope global | awk '{print $4}' | cut -d/ -f1);
    printf "%s\n" "$ips" | grep -E '^192\.168\.' | head -n1 ||
      printf "%s\n" "$ips" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | head -n1
  SH

  attr_reader :cluster

  def initialize(cluster, client: nil)
    @cluster = cluster
    @client = client
  end

  def reconcile(nodes: cluster.all_functional_nodes, addresses: nil)
    return if nodes.empty?

    addresses ||= underlay_addresses(nodes)
    nodes.each do |node|
      reconcile_node(node, nodes, addresses)
    end
    reconcile_node_addresses(nodes, addresses)
  end

  def underlay_addresses(nodes)
    nodes.to_h { |node| [node.id, node_ipv4(node)] }
  end

  def reconcile_node(node, nodes, addresses)
    sshable = node.sshable
    sshable.cmd("sudo install -d -m 0755 /opt/cni/bin /etc/cni/net.d")
    sshable.cmd("sudo tee :path > /dev/null && sudo chmod 0755 :path", path: CNI_BINARY_PATH, stdin: CNI_WRAPPER, log: false)
    sshable.cmd("sudo tee :path > /dev/null", path: CNI_CONFIG_PATH, stdin: cni_config(node), log: false)
    sshable.cmd("sudo tee :path > /dev/null && sudo sysctl --system > /dev/null", path: SYSCTL_PATH, stdin: SYSCTL_CONFIG, log: false)
    sshable.cmd("sudo tee :path > /dev/null && sudo chmod 0755 :path", path: ROUTE_SCRIPT_PATH, stdin: route_script(node, nodes, addresses), log: false)
    sshable.cmd("sudo tee :path > /dev/null && sudo systemctl daemon-reload && sudo systemctl enable --now layerrail-k8s-routes.service && sudo systemctl restart layerrail-k8s-routes.service", path: ROUTE_SERVICE_PATH, stdin: ROUTE_SERVICE, log: false)
    sshable.cmd("sudo test -x :binary && test -x /home/ubi/kubernetes/bin/ubicni && sudo ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' :config && test \"$(sysctl -n net.ipv4.ip_forward)\" = 1", binary: CNI_BINARY_PATH, config: CNI_CONFIG_PATH, log: false)
  end

  def node_ipv4(node)
    return validate_underlay_ipv4(node.vm.private_ipv4_string, node) unless node.vm.location.linode?

    ip = node.sshable.cmd(LINODE_PRIVATE_IPV4_COMMAND, log: false).strip
    fail "Unable to detect Linode private IPv4 for #{node.name}" if ip.empty?

    validate_underlay_ipv4(ip, node)
  end

  def cni_config(node)
    JSON.pretty_generate(
      "cniVersion" => "1.0.0",
      "name" => "ubicni-network",
      "type" => "ubicni",
      "ranges" => {
        "subnet_ipv6" => pod_ipv6_subnet(node).to_s,
        "subnet_ula_ipv6" => node.vm.nics.first.private_ipv6.to_s,
        "subnet_ipv4" => node.vm.nics.first.private_ipv4.to_s,
      },
    ) + "\n"
  end

  def pod_ipv6_subnet(node)
    vm = node.vm
    return vm.nics.first.private_ipv6 if provider_backed_vm?(vm)

    NetAddr::IPv6Net.new(vm.ephemeral_net6.network, NetAddr::Mask128.new(vm.ephemeral_net6.netmask.prefix_len + 1))
  end

  def route_script(node, nodes, addresses)
    topology = vxlan_topology(nodes)
    local = topology.fetch(node.id)
    peers = nodes.reject { it.id == node.id }.map do |peer|
      peer_network = topology.fetch(peer.id)
      ipv6_routes = [peer.vm.nics.first.private_ipv6, pod_ipv6_subnet(peer)].uniq(&:to_s).map do |cidr|
        "ip -6 route replace #{cidr} via #{peer_network.fetch(:tunnel_ipv6)} dev #{VXLAN_DEVICE} onlink proto #{ROUTE_PROTOCOL}"
      end
      <<~SH.chomp
        #{underlay_route_exceptions(peer, addresses.fetch(peer.id)).join("\n")}
        bridge fdb append 00:00:00:00:00:00 dev #{VXLAN_DEVICE} dst #{addresses.fetch(peer.id)} self permanent
        bridge fdb append #{peer_network.fetch(:mac)} dev #{VXLAN_DEVICE} dst #{addresses.fetch(peer.id)} self permanent
        ip neigh replace #{peer_network.fetch(:tunnel_ipv4)} lladdr #{peer_network.fetch(:mac)} nud permanent dev #{VXLAN_DEVICE}
        ip -6 neigh replace #{peer_network.fetch(:tunnel_ipv6)} lladdr #{peer_network.fetch(:mac)} nud permanent dev #{VXLAN_DEVICE}
        ip route replace #{peer_network.fetch(:tunnel_ipv4)}/32 dev #{VXLAN_DEVICE} proto #{ROUTE_PROTOCOL}
        ip -6 route replace #{peer_network.fetch(:tunnel_ipv6)}/128 dev #{VXLAN_DEVICE} proto #{ROUTE_PROTOCOL}
        ip route replace #{peer.vm.nics.first.private_ipv4} via #{peer_network.fetch(:tunnel_ipv4)} dev #{VXLAN_DEVICE} onlink proto #{ROUTE_PROTOCOL}
        #{ipv6_routes.join("\n")}
        ip route get #{addresses.fetch(peer.id)} | grep -Fv "dev #{VXLAN_DEVICE}" > /dev/null
      SH
    end
    <<~SH
      #!/bin/sh
      set -eu
      modprobe vxlan 2>/dev/null || true
      recreate_vxlan=false
      if ip link show #{VXLAN_DEVICE} > /dev/null 2>&1; then
        ip -d link show #{VXLAN_DEVICE} | grep -F "vxlan id #{vxlan_id} " > /dev/null || recreate_vxlan=true
        ip -d link show #{VXLAN_DEVICE} | grep -F "local #{addresses.fetch(node.id)} " > /dev/null || recreate_vxlan=true
        ip -d link show #{VXLAN_DEVICE} | grep -F "dstport #{VXLAN_PORT} " > /dev/null || recreate_vxlan=true
      else
        recreate_vxlan=true
      fi
      if [ "$recreate_vxlan" = true ]; then
        ip link del #{VXLAN_DEVICE} 2>/dev/null || true
        ip link add #{VXLAN_DEVICE} address #{local.fetch(:mac)} type vxlan id #{vxlan_id} local #{addresses.fetch(node.id)} dstport #{VXLAN_PORT} nolearning
      fi
      ip link set dev #{VXLAN_DEVICE} address #{local.fetch(:mac)} mtu 1400 up
      ip addr replace #{local.fetch(:tunnel_ipv4)}/32 dev #{VXLAN_DEVICE}
      ip -6 addr replace #{local.fetch(:tunnel_ipv6)}/128 dev #{VXLAN_DEVICE}
      ip route flush proto #{ROUTE_PROTOCOL} 2>/dev/null || true
      ip -6 route flush proto #{ROUTE_PROTOCOL} 2>/dev/null || true
      ip neigh flush dev #{VXLAN_DEVICE} 2>/dev/null || true
      ip -6 neigh flush dev #{VXLAN_DEVICE} 2>/dev/null || true
      bridge fdb flush dev #{VXLAN_DEVICE} 2>/dev/null || true
      preserve_underlay_route() {
        address="$1"
        route="$(ip -4 route get "$address" | head -n1)"
        device="$(printf '%s\n' "$route" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        gateway="$(printf '%s\n' "$route" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}')"
        test -n "$device"
        if [ -n "$gateway" ]; then
          ip route replace "$address/32" via "$gateway" dev "$device" proto #{ROUTE_PROTOCOL}
        else
          ip route replace "$address/32" dev "$device" proto #{ROUTE_PROTOCOL}
        fi
      }
      #{peers.join("\n")}
    SH
  end

  def underlay_route_exceptions(peer, peer_ipv4)
    routes = []
    if IPAddr.new(peer.vm.nics.first.private_ipv4.to_s).include?(peer_ipv4)
      routes << "preserve_underlay_route #{peer_ipv4}"
    end
    routes
  end

  def vxlan_topology(nodes)
    prefix = Digest::SHA256.hexdigest(cluster.id.to_s)
    ipv6_prefix = "fd42:#{prefix[0, 4]}:#{prefix[4, 4]}:#{prefix[8, 4]}"
    topology = nodes.to_h do |node|
      digest = Digest::SHA256.hexdigest("#{cluster.id}:#{node.id}")
      ipv4_offset = digest[0, 8].to_i(16) & 0x3f_ffff
      tunnel_ipv4 = IPAddr.new(IPAddr.new("100.64.0.0").to_i + ipv4_offset + 1, Socket::AF_INET).to_s
      [node.id, {
        mac: "02:6c:72:#{digest[8, 2]}:#{digest[10, 2]}:#{digest[12, 2]}",
        tunnel_ipv4:,
        tunnel_ipv6: "#{ipv6_prefix}:#{digest[16, 4]}:#{digest[20, 4]}:#{digest[24, 4]}:#{digest[28, 4]}",
      }]
    end
    duplicate_ipv4 = topology.values.group_by { it[:tunnel_ipv4] }.find { |_, values| values.length > 1 }&.first
    fail "Kubernetes VXLAN tunnel IPv4 collision at #{duplicate_ipv4}" if duplicate_ipv4

    topology
  end

  def vxlan_id
    (Digest::SHA256.hexdigest(cluster.id.to_s)[0, 6].to_i(16) % 16_777_214) + 1
  end

  def reconcile_node_addresses(nodes, addresses)
    client = @client || cluster.client
    nodes.each do |node|
      client.set_node_addresses(
        node.name,
        [
          {"type" => "InternalIP", "address" => addresses.fetch(node.id)},
          {"type" => "InternalIP", "address" => node.vm.ip6.to_s},
          {"type" => "Hostname", "address" => node.name},
        ],
      )
    end
  end

  def provider_backed_vm?(vm)
    vm.location.linode? || vm.location.azure?
  end

  def validate_underlay_ipv4(value, node)
    ip = IPAddr.new(value)
    fail "Invalid IPv4 underlay address for #{node.name}: #{value}" unless ip.ipv4?

    ip.to_s
  rescue IPAddr::InvalidAddressError
    fail "Invalid IPv4 underlay address for #{node.name}: #{value}"
  end
end
