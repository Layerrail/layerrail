# frozen_string_literal: true

class Prog::Kubernetes::ProvisionKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def node
    @node ||= KubernetesNode[frame["node_id"]]
  end

  def kubernetes_nodepool
    return @kubernetes_nodepool if defined?(@kubernetes_nodepool)
    @kubernetes_nodepool = KubernetesNodepool[frame["nodepool_id"]]
  end

  def vm
    @vm ||= node.vm
  end

  def node_ipv4
    vm.location.linode? ? vm.ip4 : vm.private_ipv4
  end

  # We need to create a random ula cidr for the cluster services subnet with
  # a NetMask of /108
  # For reference read here:
  # https://github.com/kubernetes/kubernetes/blob/44c230bf5c321056e8bc89300b37c497f464f113/cmd/kubeadm/app/constants/constants.go#L251-L255
  # This is an excerpt from the link:
  # MaximumBitsForServiceSubnet defines maximum possible size of the service subnet in terms of bits.
  # For example, if the value is 20, then the largest supported service subnet is /12 for IPv4 and /108 for IPv6.
  # Note however that anything in between /108 and /112 will be clamped to /112 due to the limitations of the underlying allocation logic.
  # MaximumBitsForServiceSubnet = 20
  def random_ula_cidr
    random_bytes = 0xfd.chr + SecureRandom.bytes(13)
    high_bits = random_bytes[0...8].unpack1("Q>")
    low_bits = (random_bytes[8...14] + "\x00\x00").unpack1("Q>")
    network_address = NetAddr::IPv6.new((high_bits << 64) | low_bits)
    NetAddr::IPv6Net.new(network_address, NetAddr::Mask128.new(108))
  end

  def before_run
    if kubernetes_cluster.strand.label == "destroy" && strand.label != "destroy"
      pop "provisioning canceled"
    end
  end

  label def start
    register_deadline(nil, 20 * 60)

    name, vm_size, storage_size_gib = if kubernetes_nodepool
      ["#{kubernetes_nodepool.ubid}-#{SecureRandom.alphanumeric(5).downcase}",
        kubernetes_nodepool.target_node_size,
        kubernetes_nodepool.target_node_storage_size_gib]
    else
      ["#{kubernetes_cluster.ubid}-#{SecureRandom.alphanumeric(5).downcase}",
        kubernetes_cluster.target_node_size,
        kubernetes_cluster.target_node_storage_size_gib]
    end

    storage_volumes = [{encrypted: true, size_gib: storage_size_gib}] if storage_size_gib

    boot_image = "kubernetes-#{kubernetes_cluster.version.tr(".", "_")}"

    node = Prog::Kubernetes::KubernetesNodeNexus.assemble(
      Config.kubernetes_service_project_id,
      sshable_unix_user: "ubi",
      name:,
      location_id: kubernetes_cluster.location.id,
      size: vm_size,
      storage_volumes:,
      boot_image:,
      private_subnet_id: kubernetes_cluster.private_subnet_id,
      enable_ip4: true,
      kubernetes_cluster_id: kubernetes_cluster.id,
      kubernetes_nodepool_id: kubernetes_nodepool&.id,
    ).subject
    vm = node.vm

    update_stack({"node_id" => node.id})

    unless kubernetes_nodepool
      kubernetes_cluster.api_server_lb.add_vm(vm)
    end

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    nap 5 unless vm.strand.label == "wait"

    prepare_linode_kubernetes_node

    outbound_interface = vm.location.linode? ? "eth0" : "ens3"
    nft_rules = <<~NFT
      #!/usr/sbin/nft -f
      flush ruleset

      table ip nat {
        chain postrouting {
          type nat hook postrouting priority 100;
          ip saddr #{vm.nics.first.private_ipv4} oifname "#{outbound_interface}" masquerade
        }
      }

      table ip6 pod_access {
        chain ingress_egress_control {
          type filter hook forward priority filter; policy drop;
          # allow access to the vm itself in order to not break the normal functionality of Clover and SSH
          ip6 daddr #{vm.ip6} ct state established,related,new counter accept
          ip6 saddr #{vm.ip6} ct state established,related,new counter accept

          # not allow new connections from internet but allow new connections from inside
          ip6 daddr #{vm.ephemeral_net6} ct state established,related counter accept
          ip6 saddr #{vm.ephemeral_net6} ct state established,related,new counter accept

          # used for internal private ipv6 communication between pods
          ip6 saddr #{kubernetes_cluster.private_subnet.net6} ct state established,related,new counter accept
          ip6 daddr #{kubernetes_cluster.private_subnet.net6} ct state established,related,new counter accept
        }
      }
    NFT
    vm.sshable.cmd("sudo tee /etc/nftables.conf > /dev/null", stdin: nft_rules)
    vm.sshable.cmd("sudo systemctl enable --now nftables")
    vm.sshable.cmd "sudo systemctl enable --now kubelet"

    bud Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  def prepare_linode_kubernetes_node
    return unless vm.location.linode?

    repo_version = kubernetes_cluster.version
    marker = "/var/lib/layerrail-linode-kubernetes-prepared-#{repo_version.tr(".", "_")}"
    vm.sshable.cmd(<<~SH)
set -ueo pipefail
if command -v kubelet >/dev/null && command -v kubeadm >/dev/null && command -v kubectl >/dev/null && [ -f #{marker} ]; then
  exit 0
fi
sudo install -d -m 0755 /etc/apt/keyrings
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd
sudo swapoff -a || true
sudo sed -i.bak '/[[:space:]]swap[[:space:]]/d' /etc/fstab
sudo modprobe overlay || true
sudo modprobe br_netfilter || true
sudo sed -i '/ #{vm.name}$/d' /etc/hosts
echo '#{node_ipv4} #{vm.name}' | sudo tee -a /etc/hosts >/dev/null
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
sudo sysctl --system
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
curl -fsSL https://pkgs.k8s.io/core:/stable:/#{repo_version}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg.tmp
sudo mv /etc/apt/keyrings/kubernetes-apt-keyring.gpg.tmp /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/#{repo_version}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
sudo touch #{marker}
    SH
  end

  label def wait_bootstrap_rhizome
    reap(:assign_role)
  end

  label def assign_role
    hop_join_worker if kubernetes_nodepool

    hop_init_cluster if kubernetes_cluster.nodes.count == 1

    hop_join_control_plane
  end

  label def init_cluster
    state = vm.sshable.d_check("init_kubernetes_cluster")
    case state
    when "Succeeded"
      Page.from_tag_parts("KubernetesNodeInitClusterFailed", node.ubid)&.incr_resolve
      hop_install_cni
    when "NotStarted"
      params = {
        node_name: vm.name,
        cluster_name: kubernetes_cluster.name,
        lb_hostname: kubernetes_cluster.endpoint,
        port: "443",
        private_subnet_cidr4: kubernetes_cluster.private_subnet.net4,
        private_subnet_cidr6: kubernetes_cluster.private_subnet.net6,
        node_ipv4: node_ipv4,
        node_ipv6: vm.ip6,
        service_subnet_cidr6: random_ula_cidr,
      }
      vm.sshable.d_run("init_kubernetes_cluster", "/home/ubi/kubernetes/bin/init-cluster", stdin: JSON.generate(params), log: false)
      nap 30
    when "InProgress"
      nap 10
    when "Failed"
      Clog.emit("init kubernetes cluster failed", {logs: vm.sshable.d_logs("init_kubernetes_cluster")})
      Prog::PageNexus.assemble(
        "init kubernetes cluster failed on node #{node.ubid}",
        ["KubernetesNodeInitClusterFailed", node.ubid],
        [node.ubid, kubernetes_cluster.ubid],
      )
      nap 30
    else
      Clog.emit("got unknown state from daemonizer2 check: #{state}")
      nap 30
    end
  end

  label def join_control_plane
    state = vm.sshable.d_check("join_control_plane")
    case state
    when "Succeeded"
      Page.from_tag_parts("KubernetesNodeJoinControlPlaneFailed", node.ubid)&.incr_resolve
      hop_install_cni
    when "NotStarted"
      cp_sshable = kubernetes_cluster.sshable
      params = {
        is_control_plane: true,
        node_name: vm.name,
        endpoint: "#{kubernetes_cluster.endpoint}:443",
        join_token: cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).chomp,
        certificate_key: cp_sshable.cmd("sudo kubeadm init phase upload-certs --upload-certs", log: false)[/certificate key:\n(.*)/, 1],
        discovery_token_ca_cert_hash: cp_sshable.cmd("sudo kubeadm token create --print-join-command", log: false)[/discovery-token-ca-cert-hash (\S+)/, 1],
        node_ipv4: node_ipv4,
        node_ipv6: vm.ip6,
      }
      vm.sshable.d_run("join_control_plane", "kubernetes/bin/join-node", stdin: JSON.generate(params), log: false)
      nap 15
    when "InProgress"
      nap 10
    when "Failed"
      Clog.emit("join cp node to cluster failed", {logs: vm.sshable.d_logs("join_control_plane")})
      Prog::PageNexus.assemble(
        "join cp node to cluster failed on node #{node.ubid}",
        ["KubernetesNodeJoinControlPlaneFailed", node.ubid],
        [node.ubid, kubernetes_cluster.ubid],
      )
      nap 30
    else
      Clog.emit("got unknown state from daemonizer2 check: #{state}")
      nap 30
    end
  end

  label def join_worker
    state = vm.sshable.d_check("join_worker")
    case state
    when "Succeeded"
      Page.from_tag_parts("KubernetesNodeJoinWorkerFailed", node.ubid)&.incr_resolve
      hop_install_cni
    when "NotStarted"
      cp_sshable = kubernetes_cluster.sshable
      params = {
        is_control_plane: false,
        node_name: vm.name,
        endpoint: "#{kubernetes_cluster.endpoint}:443",
        join_token: cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).tr("\n", ""),
        discovery_token_ca_cert_hash: cp_sshable.cmd("sudo kubeadm token create --print-join-command", log: false)[/discovery-token-ca-cert-hash (\S+)/, 1],
        node_ipv4: node_ipv4,
        node_ipv6: vm.ip6,
      }
      vm.sshable.d_run("join_worker", "kubernetes/bin/join-node", stdin: JSON.generate(params), log: false)
      nap 15
    when "InProgress"
      nap 10
    when "Failed"
      Clog.emit("join worker node to cluster failed", {logs: vm.sshable.d_logs("join_worker")})
      Prog::PageNexus.assemble(
        "join worker node to cluster failed on node #{node.ubid}",
        ["KubernetesNodeJoinWorkerFailed", node.ubid],
        [node.ubid, kubernetes_cluster.ubid],
      )
      nap 30
    else
      Clog.emit("got unknown state from daemonizer2 check: #{state}")
      nap 30
    end
  end

  label def install_cni
    pod_ipv6_subnet = if vm.location.linode?
      vm.nics.first.private_ipv6
    else
      NetAddr::IPv6Net.new(vm.ephemeral_net6.network, NetAddr::Mask128.new(vm.ephemeral_net6.netmask.prefix_len + 1))
    end
    cni_config = <<CONFIG
{
  "cniVersion": "1.0.0",
  "name": "ubicni-network",
  "type": "ubicni",
  "ranges":{
      "subnet_ipv6": "#{pod_ipv6_subnet}",
      "subnet_ula_ipv6": "#{vm.nics.first.private_ipv6}",
      "subnet_ipv4": "#{vm.nics.first.private_ipv4}"
  }
}
CONFIG
    vm.sshable.cmd("sudo mkdir -p /etc/cni/net.d")
    vm.sshable.cmd("sudo tee /etc/cni/net.d/ubicni-config.json", stdin: cni_config)
    hop_approve_new_csr
  end

  label def approve_new_csr
    approved_csr = kubernetes_cluster.client.get_csr(node.name, csr_status: "Approved")
    if approved_csr.empty?
      pending_csr = kubernetes_cluster.client.get_csr(node.name, csr_status: "Pending")
      nap 5 if pending_csr.empty?
      kubernetes_cluster.client.approve_csr(pending_csr)
    end
    kubernetes_cluster.incr_sync_internal_dns_config
    kubernetes_cluster.incr_sync_worker_mesh
    pop({node_id: node.id})
  end
end
