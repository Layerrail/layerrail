# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::ProvisionKubernetesNode do
  subject(:prog) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Kubernetes::ProvisionKubernetesNode", label: "start") }

  let(:project) {
    Project.create(name: "default")
  }
  let(:kubernetes_location) {
    Option.kubernetes_locations.find { it.name == "linode-us-lax" } || Option.kubernetes_locations.first
  }
  let(:kubernetes_location_id) { kubernetes_location.id }
  let(:expected_node_ipv4) { kubernetes_location.linode? ? "192.168.151.139" : "172.19.145.65" }
  let(:expected_node_ipv4_regex) { Regexp.escape(expected_node_ipv4) }
  let(:expected_node_ipv6_regex) { Regexp.escape(prog.vm.ip6.to_s) }
  let(:expected_join_endpoint_regex) { "somelb\\..*:443" }
  let(:join_token_command) {
    kubernetes_location.linode? ? a_string_matching(/tmp=\$\(mktemp\).*sudo env KUBECONFIG="\$tmp" kubeadm token create --ttl 24h --usages signing,authentication.*sudo rm -f "\$tmp"/) : "sudo kubeadm token create --ttl 24h --usages signing,authentication"
  }
  let(:join_command_command) {
    kubernetes_location.linode? ? a_string_matching(/tmp=\$\(mktemp\).*sudo env KUBECONFIG="\$tmp" kubeadm token create --print-join-command.*sudo rm -f "\$tmp"/) : "sudo kubeadm token create --print-join-command"
  }
  let(:upload_certs_command) {
    kubernetes_location.linode? ? a_string_matching(/tmp=\$\(mktemp\).*sudo env KUBECONFIG="\$tmp" kubeadm init phase upload-certs --upload-certs.*sudo rm -f "\$tmp"/) : "sudo kubeadm init phase upload-certs --upload-certs"
  }
  let(:expected_standard_4_storage_size) {
    kubernetes_location.linode? ? Option.linode_plan("standard", 4, size_name: "standard-4").disk_gib : 37
  }
  let(:expected_standard_8_storage_size) {
    kubernetes_location.linode? ? Option.linode_plan("standard", 8, size_name: "standard-8").disk_gib : 78
  }
  let(:default_node_storage_size) {
    kubernetes_location.linode? ? Option.linode_plan("standard", 4, size_name: "standard-4").disk_gib : 80
  }
  let(:subnet) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test", location_id: kubernetes_location_id, ipv4_range: "172.19.0.0/16", ipv6_range: "fd40:1a0a:8d48:182a::/64").subject
  }

  let(:kubernetes_cluster) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "k8scluster",
      version: Option.selectable_kubernetes_versions.first,
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: kubernetes_location_id,
      project_id: project.id,
      target_node_size: "standard-4",
      target_node_storage_size_gib: 37,
    ).subject

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    st = Prog::Kubernetes::KubernetesNodeNexus.assemble(
      project.id,
      sshable_unix_user: "ubi",
      name: "cp-node",
      location_id: kubernetes_location_id,
      size: "standard-4",
      storage_volumes: [{encrypted: true, size_gib: 40}],
      boot_image: Option.selectable_kubernetes_versions.first,
      private_subnet_id: subnet.id,
      enable_ip4: true,
      kubernetes_cluster_id: kc.id,
    )
    st.subject.update(state: "active")
    kc.update(api_server_lb_id: lb.id)
  }

  let(:node) {
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, ipv4_addr: "172.19.145.64/26", ipv6_addr: "fd40:1a0a:8d48:182a::/79").subject
    vm = Prog::Vm::Nexus.assemble_with_sshable(Config.kubernetes_service_project_id, name: "test-vm", location_id: kubernetes_location_id, private_subnet_id: subnet.id, nic_id: nic.id).subject
    vm.update(ephemeral_net6: "2001:db8:85a3:73f2:1c4a::/79", created_at: Time.now - 1)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: "#{expected_node_ipv4}/32") if kubernetes_location.linode?
    KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kubernetes_cluster.id)
  }

  let(:kubernetes_nodepool) { KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id, target_node_size: "standard-8", target_node_storage_size_gib: 78) }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(project.id)
    allow(prog).to receive_messages(kubernetes_cluster:, frame: {"node_id" => node.id})
    allow(prog).to receive(:node_ipv4).and_return(expected_node_ipv4)
  end

  describe "random_ula_cidr" do
    it "returns a /108 subnet" do
      cidr = prog.random_ula_cidr
      expect(cidr.netmask.prefix_len).to eq(108)
    end

    it "returns an address in the fd00::/8 range" do
      cidr = prog.random_ula_cidr
      ula_range = NetAddr::IPv6Net.parse("fd00::/8")
      expect(ula_range.cmp(cidr)).to be(-1)
    end
  end

  describe "node" do
    it "finds the right node" do
      node = KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kubernetes_cluster.id)
      expect(prog).to receive(:frame).and_return({"node_id" => node.id})
      expect(prog.node.id).to eq(node.id)
    end
  end

  describe "#node_ipv4" do
    before { allow(prog).to receive(:node_ipv4).and_call_original }

    it "detects the provider private IPv4 for Linode nodes" do
      allow(prog.vm.location).to receive(:linode?).and_return(true)
      sshable = Sshable.new
      allow(prog.vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:_cmd).with(described_class::LINODE_PRIVATE_IPV4_COMMAND).and_return("192.168.151.139\n")

      expect(prog.node_ipv4).to eq "192.168.151.139"
    end

    it "uses the LayerRail private IPv4 for non-Linode nodes" do
      allow(prog.vm.location).to receive(:linode?).and_return(false)

      expect(prog.node_ipv4.to_s).to eq "172.19.145.65"
    end
  end

  describe "#node_kubeconfig" do
    let(:raw_kubeconfig) {
      {
        "apiVersion" => "v1",
        "clusters" => [
          {
            "name" => "kubernetes",
            "cluster" => {
              "server" => "https://somelb.example.com:443",
              "certificate-authority-data" => "ca",
            },
          },
        ],
        "contexts" => [],
        "users" => [],
      }.to_yaml
    }

    it "returns the cluster kubeconfig when it is valid" do
      expect(kubernetes_cluster).to receive(:kubeconfig).with(swallow_connection_exception: true).and_return(raw_kubeconfig)

      expect(prog.node_kubeconfig).to eq raw_kubeconfig
    end

    it "raises if kubeconfig cannot be fetched" do
      expect(kubernetes_cluster).to receive(:kubeconfig).with(swallow_connection_exception: true).and_return(nil)

      expect { prog.node_kubeconfig }.to raise_error(described_class::JoinParameterError, /Unable to fetch kubeconfig/)
    end
  end

  describe "#install_node_kubeconfig" do
    before { allow(prog).to receive(:node_kubeconfig).and_return("apiVersion: v1\n") }

    it "installs the kubeconfig for the node ssh user" do
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo install -d -m 0700 -o ubi -g ubi /home/ubi/.kube", log: false).ordered
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo tee /home/ubi/.kube/config > /dev/null", stdin: "apiVersion: v1\n", log: false).ordered
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo chown ubi:ubi /home/ubi/.kube/config && sudo chmod 600 /home/ubi/.kube/config", log: false).ordered

      prog.install_node_kubeconfig
    end
  end

  describe "#before_run" do
    it "destroys itself if the kubernetes cluster is getting deleted" do
      kubernetes_cluster.strand.update(label: "something")
      expect(kubernetes_cluster.strand.label).to eq("something")
      prog.before_run # Nothing happens

      kubernetes_cluster.strand.label = "destroy"
      expect { prog.before_run }.to exit({"msg" => "provisioning canceled"})

      prog.strand.label = "destroy"
      prog.before_run # Nothing happens
    end
  end

  describe "#start" do
    it "creates a control plane node and hops if a nodepool is not given" do
      expect(prog.kubernetes_nodepool).to be_nil
      expect(kubernetes_cluster.nodes.count).to eq(2)

      expect { prog.start }.to hop("bootstrap_rhizome")
      expect(prog.strand.stack.first["deadline_target"]).to be_nil
      expect(Time.parse(prog.strand.stack.first["deadline_at"])).to be_within(60).of(Time.now + 20 * 60)
      kubernetes_cluster.reload

      expect(kubernetes_cluster.nodes.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms_dataset.first(name: /#{kubernetes_cluster.ubid}-/)
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.vcpus).to eq(4)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq(expected_standard_4_storage_size)
      expect(new_vm.boot_image).to eq("kubernetes-#{Option.selectable_kubernetes_versions.first.tr(".", "_")}")
      expect(KubernetesNode[vm_id: new_vm.id].state).to eq("provisioning")
    end

    it "creates a worker node and hops if a nodepool is given" do
      expect(prog).to receive(:frame).and_return({"nodepool_id" => kubernetes_nodepool.id})
      expect(kubernetes_nodepool.nodes.count).to eq(0)

      expect { prog.start }.to hop("bootstrap_rhizome")

      expect(kubernetes_nodepool.reload.nodes.count).to eq(1)

      new_vm = kubernetes_nodepool.nodes.last.vm
      expect(new_vm.name).to start_with("#{kubernetes_nodepool.ubid}-")
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.vcpus).to eq(8)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq(expected_standard_8_storage_size)
      expect(new_vm.boot_image).to eq("kubernetes-#{Option.selectable_kubernetes_versions.first.tr(".", "_")}")
      expect(KubernetesNode[vm_id: new_vm.id].state).to eq("provisioning")
    end

    it "assigns the default storage size if not specified" do
      kubernetes_cluster.update(target_node_storage_size_gib: nil)

      expect(kubernetes_cluster.nodes.count).to eq(2)

      expect { prog.start }.to hop("bootstrap_rhizome")
      kubernetes_cluster.reload

      expect(kubernetes_cluster.nodes.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms_dataset.first(name: /#{kubernetes_cluster.ubid}-/)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq default_node_storage_size
    end
  end

  describe "#bootstrap_rhizome" do
    it "waits until the node is ready" do
      st = instance_double(Strand, label: "non-wait")
      expect(prog.node.vm).to receive(:strand).and_return(st)
      expect { prog.bootstrap_rhizome }.to nap(5)
    end

    it "buds a bootstrap rhizome process" do
      prog.node.vm.strand.update(label: "wait")

      expect(prog).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => prog.node.vm.id, "user" => "ubi"})
      expect { prog.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to prepare_node_runtime if there are no sub-programs running" do
      st.update(prog: "Kubernetes::ProvisionKubernetesNode", label: "wait_bootstrap_rhizome", stack: [{}])
      expect { prog.wait_bootstrap_rhizome }.to hop("prepare_node_runtime")
    end

    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::ProvisionKubernetesNode", label: "wait_bootstrap_rhizome", stack: [{}])
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { prog.wait_bootstrap_rhizome }.to nap(120)
    end
  end

  describe "#prepare_node_runtime" do
    before do
      allow(prog.vm).to receive(:sshable).and_return(Sshable.new)
      allow(prog.vm.location).to receive(:linode?).and_return(true)
    end

    it "runs the Linode Kubernetes preparation script if it's not started and extends the provisioning deadline" do
      expect(prog.vm.sshable).to receive(:d_check).with("prepare_linode_kubernetes_node").and_return("NotStarted")
      expect(prog).to receive(:register_deadline).with("assign_role", 20 * 60, allow_extension: 24 * 60 * 60)
      expect(prog).to receive(:linode_kubernetes_prepare_script).and_return("prepare script")
      expect(prog.vm.sshable).to receive(:d_run).with("prepare_linode_kubernetes_node", "bash", "-s", stdin: "prepare script", log: false)

      expect { prog.prepare_node_runtime }.to nap(15)
    end

    it "extends the provisioning deadline while Linode Kubernetes preparation is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("prepare_linode_kubernetes_node").and_return("InProgress")
      expect(prog).to receive(:register_deadline).with("assign_role", 20 * 60, allow_extension: 24 * 60 * 60)

      expect { prog.prepare_node_runtime }.to nap(10)
    end
  end

  describe "#configure_kubernetes_node_services" do
    before do
      allow(prog.vm).to receive(:sshable).and_return(Sshable.new)
      allow(prog.vm.location).to receive(:linode?).and_return(true)
    end

    it "writes Kubernetes-owned nftables tables without flushing load balancer rules" do
      expect(prog.vm.sshable).to receive(:_cmd).with(
        "sudo tee /etc/nftables.conf > /dev/null",
        stdin: satisfy { |rules|
          rules.include?("table ip layerrail_kubernetes_nat") &&
            rules.include?("table ip6 layerrail_pod_access") &&
            !rules.include?("flush ruleset")
        },
      )
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo systemctl enable --now nftables")
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo systemctl enable kubelet")

      prog.configure_kubernetes_node_services
    end
  end

  describe "#configure_azure_join_endpoint_resolution" do
    before do
      allow(prog.vm).to receive(:sshable).and_return(Sshable.new)
    end

    it "does nothing outside Azure" do
      allow(prog.vm.location).to receive(:azure?).and_return(false)
      expect(prog.vm.sshable).not_to receive(:_cmd)

      prog.configure_azure_join_endpoint_resolution
    end

    it "maps the API endpoint hostname to the control-plane private IPv4 on Azure" do
      allow(prog.vm.location).to receive(:azure?).and_return(true)
      cp_vm = instance_double(Vm, private_ipv4_string: "10.240.37.1")
      cp_node = instance_double(KubernetesNode, vm: cp_vm)
      allow(prog).to receive(:control_plane_join_node).and_return(cp_node)

      expect(prog.vm.sshable).to receive(:_cmd).with(
        "sudo ruby -e #{described_class::HOSTS_REWRITE.shellescape} /etc/hosts 10.240.37.1 #{kubernetes_cluster.endpoint.shellescape}",
        log: false,
      )

      prog.configure_azure_join_endpoint_resolution
    end
  end

  describe "#assign_role" do
    it "hops to init_cluster if this is the first node of the cluster" do
      expect(prog.kubernetes_cluster.nodes).to receive(:count).and_return(1)
      expect { prog.assign_role }.to hop("init_cluster")
    end

    it "hops to join_control_plane if this is the not the first node of the cluster" do
      expect(prog.kubernetes_cluster.nodes.count).to eq(2)
      expect { prog.assign_role }.to hop("join_control_plane")
    end

    it "hops to join_worker if a nodepool is specified to the prog" do
      expect(prog).to receive(:kubernetes_nodepool).and_return(kubernetes_nodepool)
      expect { prog.assign_role }.to hop("join_worker")
    end
  end

  describe "#init_cluster" do
    before do
      allow(prog.vm).to receive(:sshable).and_return(Sshable.new)
      allow(prog).to receive(:install_node_kubeconfig)
    end

    it "runs the init_cluster script if it's not started" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("NotStarted")
      expect(prog.vm.sshable).to receive(:d_run).with(
        "init_kubernetes_cluster", "/home/ubi/kubernetes/bin/init-cluster",
        stdin: /{"node_name":"test-vm","cluster_name":"k8scluster","lb_hostname":"somelb\..*","port":"443","private_subnet_cidr4":"172.19.0.0\/16","private_subnet_cidr6":"fd40:1a0a:8d48:182a::\/64","node_ipv4":"#{expected_node_ipv4_regex}","node_ipv6":"#{expected_node_ipv6_regex}"/, log: false,
      )
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)

      expect { prog.init_cluster }.to nap(30)
    end

    it "naps if the init_cluster script is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("InProgress")
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)
      expect { prog.init_cluster }.to nap(10)
    end

    it "pages and naps if the init_cluster script is failed" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Failed")
      expect(prog.vm.sshable).to receive(:d_logs).with("init_kubernetes_cluster").and_return("error logs")
      expect { prog.init_cluster }.to nap(30)
      expect(Page.from_tag_parts("KubernetesNodeInitClusterFailed", prog.node.ubid)).not_to be_nil
    end

    it "resolves any open page and hops if the init_cluster script is successful" do
      Prog::PageNexus.assemble("existing", ["KubernetesNodeInitClusterFailed", prog.node.ubid], prog.node.ubid)
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Succeeded")
      expect(prog).to receive(:install_node_kubeconfig)
      expect { prog.init_cluster }.to hop("install_cni")
      page = Page.from_tag_parts("KubernetesNodeInitClusterFailed", prog.node.ubid)
      expect(page.resolve_set?).to be true
    end

    it "hops if the init_cluster script is successful and no page exists" do
      expect(Page.from_tag_parts("KubernetesNodeInitClusterFailed", prog.node.ubid)).to be_nil
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Succeeded")
      expect { prog.init_cluster }.to hop("install_cni")
    end

    it "naps if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Unknown")
      expect { prog.init_cluster }.to nap(30)
    end
  end

  describe "#join_control_plane" do
    before do
      allow(prog.vm).to receive(:sshable).and_return(Sshable.new)
      allow(prog).to receive(:install_node_kubeconfig)
    end

    it "runs the join_control_plane script if it's not started" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("NotStarted")

      sshable = Sshable.new
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:_cmd).with(join_token_command, log: false).and_return("jt\n")
      expect(sshable).to receive(:_cmd).with(upload_certs_command, log: false).and_return("something\ncertificate key:\nck")
      expect(sshable).to receive(:_cmd).with(join_command_command, log: false).and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:d_run).with(
        "join_control_plane", "kubernetes/bin/join-node",
        stdin: /{"is_control_plane":true,"node_name":"test-vm","endpoint":"#{expected_join_endpoint_regex}","join_token":"jt","certificate_key":"ck","discovery_token_ca_cert_hash":"dtcch","node_ipv4":"#{expected_node_ipv4_regex}","node_ipv6":"#{expected_node_ipv6_regex}"}/,
        log: false,
      )
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)

      expect { prog.join_control_plane }.to nap(15)
    end

    it "retries later if control-plane join parameters cannot be prepared" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("NotStarted")

      sshable = Sshable.new
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:_cmd).with(join_token_command, log: false)
        .and_raise(Sshable::SshError.new("sudo kubeadm token create --ttl 24h --usages signing,authentication", "", "kubeadm unavailable", 1, nil))
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)
      expect(prog.vm.sshable).not_to receive(:d_run)

      expect { prog.join_control_plane }.to nap(30)
    end

    it "naps if the join_control_plane script is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("InProgress")
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)
      expect { prog.join_control_plane }.to nap(10)
    end

    it "pages and naps if the join_control_plane script is failed" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Failed")
      expect(prog.vm.sshable).to receive(:d_logs).with("join_control_plane").and_return("error logs")
      expect { prog.join_control_plane }.to nap(30)
      expect(Page.from_tag_parts("KubernetesNodeJoinControlPlaneFailed", prog.node.ubid)).not_to be_nil
    end

    it "resolves any open page and hops if the join_control_plane script is successful" do
      Prog::PageNexus.assemble("existing", ["KubernetesNodeJoinControlPlaneFailed", prog.node.ubid], prog.node.ubid)
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Succeeded")
      expect(prog).to receive(:install_node_kubeconfig)
      expect { prog.join_control_plane }.to hop("install_cni")
      page = Page.from_tag_parts("KubernetesNodeJoinControlPlaneFailed", prog.node.ubid)
      expect(page.resolve_set?).to be true
    end

    it "hops if the join_control_plane script is successful and no page exists" do
      expect(Page.from_tag_parts("KubernetesNodeJoinControlPlaneFailed", prog.node.ubid)).to be_nil
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Succeeded")
      expect { prog.join_control_plane }.to hop("install_cni")
    end

    it "naps if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Unknown")
      expect { prog.join_control_plane }.to nap(30)
    end
  end

  describe "#join_worker" do
    before {
      allow(prog.vm).to receive(:sshable).and_return(Sshable.new)
      allow(prog).to receive(:kubernetes_nodepool).and_return(kubernetes_nodepool)
      allow(prog).to receive(:install_node_kubeconfig)
    }

    it "runs the join-worker-node script if it's not started" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("NotStarted")

      sshable = Sshable.new
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:_cmd).with(join_token_command, log: false).and_return("\njt\n")
      expect(sshable).to receive(:_cmd).with(join_command_command, log: false).and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:d_run).with(
        "join_worker", "kubernetes/bin/join-node",
        stdin: /{"is_control_plane":false,"node_name":"test-vm","endpoint":"#{expected_join_endpoint_regex}","join_token":"jt","discovery_token_ca_cert_hash":"dtcch","node_ipv4":"#{expected_node_ipv4_regex}","node_ipv6":"#{expected_node_ipv6_regex}"}/,
        log: false,
      )
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)

      expect { prog.join_worker }.to nap(15)
    end

    it "retries later if worker join parameters cannot be prepared" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("NotStarted")

      sshable = Sshable.new
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:_cmd).with(join_token_command, log: false)
        .and_raise(Sshable::SshError.new("sudo kubeadm token create --ttl 24h --usages signing,authentication", "", "kubeadm unavailable", 1, nil))
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)
      expect(prog.vm.sshable).not_to receive(:d_run)

      expect { prog.join_worker }.to nap(30)
    end

    it "naps if the join-worker-node script is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("InProgress")
      expect(prog).to receive(:register_deadline).with("install_cni", 20 * 60, allow_extension: 24 * 60 * 60)
      expect { prog.join_worker }.to nap(10)
    end

    it "pages and naps if the join-worker-node script is failed" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Failed")
      expect(prog.vm.sshable).to receive(:d_logs).with("join_worker").and_return("error logs")
      expect { prog.join_worker }.to nap(30)
      expect(Page.from_tag_parts("KubernetesNodeJoinWorkerFailed", prog.node.ubid)).not_to be_nil
    end

    it "resolves any open page and hops if the join-worker-node script is successful" do
      Prog::PageNexus.assemble("existing", ["KubernetesNodeJoinWorkerFailed", prog.node.ubid], prog.node.ubid)
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Succeeded")
      expect(prog).to receive(:install_node_kubeconfig)
      expect { prog.join_worker }.to hop("install_cni")
      page = Page.from_tag_parts("KubernetesNodeJoinWorkerFailed", prog.node.ubid)
      expect(page.resolve_set?).to be true
    end

    it "hops if the join-worker-node script is successful and no page exists" do
      expect(Page.from_tag_parts("KubernetesNodeJoinWorkerFailed", prog.node.ubid)).to be_nil
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Succeeded")
      expect { prog.join_worker }.to hop("install_cni")
    end

    it "naps if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Unknown")
      expect { prog.join_worker }.to nap(30)
    end
  end

  describe "#install_cni" do
    it "configures ubicni with the VM's ephemeral prefix" do
      expected_pod_ipv6_subnet = kubernetes_location.linode? ? "fd40:1a0a:8d48:182a::/79" : "2001:db8:85a3:73f2:1c4a::/80"
      expected_config = <<~CONFIG
        {
          "cniVersion": "1.0.0",
          "name": "ubicni-network",
          "type": "ubicni",
          "ranges":{
              "subnet_ipv6": "#{expected_pod_ipv6_subnet}",
              "subnet_ula_ipv6": "fd40:1a0a:8d48:182a::/79",
              "subnet_ipv4": "172.19.145.64/26"
          }
        }
      CONFIG
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo mkdir -p /etc/cni/net.d").ordered
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo tee /etc/cni/net.d/ubicni-config.json", stdin: expected_config).ordered
      expect { prog.install_cni }.to hop("approve_new_csr")
    end

    it "uses the VM's actual ephemeral prefix on hosts with narrow delegations" do
      prog.vm.update(ephemeral_net6: "2607:f5b7:9:1a:0:355c::/95")
      expected_pod_ipv6_subnet = kubernetes_location.linode? ? "fd40:1a0a:8d48:182a::/79" : "2607:f5b7:9:1a:0:355c:0:0/96"
      expected_config = <<~CONFIG
        {
          "cniVersion": "1.0.0",
          "name": "ubicni-network",
          "type": "ubicni",
          "ranges":{
              "subnet_ipv6": "#{expected_pod_ipv6_subnet}",
              "subnet_ula_ipv6": "fd40:1a0a:8d48:182a::/79",
              "subnet_ipv4": "172.19.145.64/26"
          }
        }
      CONFIG
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo mkdir -p /etc/cni/net.d").ordered
      expect(prog.vm.sshable).to receive(:_cmd).with("sudo tee /etc/cni/net.d/ubicni-config.json", stdin: expected_config).ordered
      expect { prog.install_cni }.to hop("approve_new_csr")
    end
  end

  describe "#approve_new_csr" do
    let(:session) { Net::SSH::Connection::Session.allocate }

    before do
      allow(kubernetes_cluster.sshable).to receive(:connect).and_return(session)
    end

    it "naps if no pending or approved csr exists yet" do
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get csr --sort-by=.metadata.creationTimestamp | awk /Approved/' && /kubelet-serving/ && /'test-vm'/ {print $1}' | tail -1").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("\n", 0))
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get csr --sort-by=.metadata.creationTimestamp | awk /Pending/' && /kubelet-serving/ && /'test-vm'/ {print $1}' | tail -1").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("\n", 0))
      expect { prog.approve_new_csr }.to nap(5)
    end

    it "skips approve if the csr is already approved" do
      prog.node.update(state: "provisioning")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get csr --sort-by=.metadata.creationTimestamp | awk /Approved/' && /kubelet-serving/ && /'test-vm'/ {print $1}' | tail -1").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("csr-abc123\n", 0))
      expect { prog.approve_new_csr }.to exit({node_id: prog.node.id})
      expect(prog.node.reload.state).to eq("active")
      expect(kubernetes_cluster.reload.sync_internal_dns_config_set?).to be true
      expect(kubernetes_cluster.reload.sync_worker_mesh_set?).to be true
    end

    it "approves the csr when it is pending" do
      prog.node.update(state: "provisioning")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get csr --sort-by=.metadata.creationTimestamp | awk /Approved/' && /kubelet-serving/ && /'test-vm'/ {print $1}' | tail -1").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("\n", 0))
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get csr --sort-by=.metadata.creationTimestamp | awk /Pending/' && /kubelet-serving/ && /'test-vm'/ {print $1}' | tail -1").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("csr-abc123\n", 0))
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s certificate approve csr-abc123").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("approved", 0))
      expect { prog.approve_new_csr }.to exit({node_id: prog.node.id})
      expect(prog.node.reload.state).to eq("active")
      expect(kubernetes_cluster.reload.sync_internal_dns_config_set?).to be true
      expect(kubernetes_cluster.reload.sync_worker_mesh_set?).to be true
    end
  end
end
