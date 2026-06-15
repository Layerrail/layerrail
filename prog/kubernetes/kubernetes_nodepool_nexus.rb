# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool

  WAIT_DEADLINE = 20 * 60
  WAIT_DEADLINE_EXTENSION = 24 * 60 * 60

  def cluster
    @cluster ||= kubernetes_nodepool.cluster
  end

  def self.assemble(name:, node_count:, kubernetes_cluster_id:, target_node_size: "standard-2", target_node_storage_size_gib: nil)
    DB.transaction do
      unless KubernetesCluster[kubernetes_cluster_id]
        fail "No existing cluster"
      end

      Validation.validate_kubernetes_worker_node_count(node_count)

      kn = KubernetesNodepool.create(name:, node_count:, kubernetes_cluster_id:, target_node_size:, target_node_storage_size_gib:)

      Strand.create_with_id(kn, prog: "Kubernetes::KubernetesNodepoolNexus", label: "start")
    end
  end

  label def start
    register_deadline("wait", 120 * 60)
    when_start_bootstrapping_set? do
      hop_bootstrap_worker_nodes
    end
    nap 10
  end

  label def bootstrap_worker_nodes
    current_node_count = kubernetes_nodepool.allocated_nodes.count
    desired_node_count = kubernetes_nodepool.node_count

    if current_node_count < desired_node_count
      (desired_node_count - current_node_count).times do
        bud Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster_id}
      end
    elsif current_node_count > desired_node_count
      excess_nodes = kubernetes_nodepool.functional_nodes.reject(&:retire_set?).first(current_node_count - desired_node_count)
      excess_nodes.each(&:incr_retire)
    end
    hop_wait_worker_node
  end

  label def wait_worker_node
    register_deadline("wait", WAIT_DEADLINE, allow_extension: WAIT_DEADLINE_EXTENSION)
    reap do
      kubernetes_nodepool.cluster.incr_update_billing_records
      hop_wait
    end
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    when_scale_worker_count_set? do
      decr_scale_worker_count
      hop_bootstrap_worker_nodes
    end
    nap 6 * 60 * 60
  end

  label def upgrade
    decr_upgrade

    nap 10 if %w[upgrade wait_upgrade].freeze.include?(cluster.strand.label) || cluster.upgrade_set?

    node_to_upgrade = kubernetes_nodepool.nodes.find do |node|
      node_version = kubernetes_nodepool.cluster.client(session: node.sshable.connect).version
      node_minor_version = node_version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i
      cluster_minor_version = kubernetes_nodepool.cluster.version.match(/^v\d+\.(\d+)$/).captures.first.to_i

      unless node_minor_version
        Prog::PageNexus.assemble(
          "Invalid version format for #{node.name} of cluster #{kubernetes_nodepool.cluster.ubid}",
          ["K8sInvalidVersion", kubernetes_nodepool.cluster.ubid, node.name],
          [kubernetes_nodepool.cluster.ubid, node.ubid],
          extra_data: {node_version:, cluster_version: kubernetes_nodepool.cluster.version},
        )
        next false
      end

      node_minor_version == cluster_minor_version - 1
    end

    hop_wait unless node_to_upgrade

    bud Prog::Kubernetes::UpgradeKubernetesNode, {"old_node_id" => node_to_upgrade.id, "nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.cluster.id}
    hop_wait_upgrade
  end

  label def wait_upgrade
    reap(:upgrade)
  end

  label def destroy
    decr_destroy
    Semaphore.incr(strand.children_dataset.select(:id), "destroy")
    schedule_nodes_for_destroy
    hop_wait_children_destroyed
  end

  label def wait_children_destroyed
    schedule_nodes_for_destroy
    reap(nap: 5) do
      kubernetes_nodepool.nodes.each(&:incr_destroy)
      nap 5 unless kubernetes_nodepool.nodes.empty?
      kubernetes_nodepool.destroy
      pop "kubernetes nodepool is deleted"
    end
  end

  def schedule_nodes_for_destroy
    kubernetes_nodepool.nodes.each(&:incr_destroy)
  end
end
