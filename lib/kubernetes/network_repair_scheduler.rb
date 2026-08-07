# frozen_string_literal: true

class Kubernetes::NetworkRepairScheduler
  def run
    scheduled = active_clusters.map do |cluster|
      cluster.all_functional_nodes.each(&:install_rhizome)
      SemSnap.use(cluster.id) { it.incr(:sync_pod_network) unless it.set?(:sync_pod_network) }
      {
        cluster: cluster.ubid,
        location: cluster.location.name,
        nodes: cluster.all_functional_nodes.count,
      }
    end

    {scheduled: scheduled.length, clusters: scheduled}
  end

  private

  def active_clusters
    KubernetesCluster
      .association_join(:strand)
      .where(Sequel[:strand][:label] => "wait")
      .exclude(Sequel[:kubernetes_cluster][:id] => Semaphore.where(name: %w[destroy destroying]).select(:strand_id))
      .all
  end
end
