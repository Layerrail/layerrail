# frozen_string_literal: true

class Clover
  def kubernetes_cluster_post(name)
    raise CloverError.new(404, "NotFound", "Kubernetes is not enabled for this LayerRail deployment") unless Config.kubernetes_enabled

    authorize("KubernetesCluster:create", @project)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    version, target_node_size = typecast_params.nonempty_str!(["version", "worker_size"])
    node_count = typecast_params.pos_int("worker_nodes", 1)
    cp_node_count = typecast_params.pos_int("cp_nodes", 1)
    node_size = Validation.validate_vm_size(target_node_size, "x64")
    if @location.linode? && !Option.kubernetes_worker_size_options(location: @location).include?(node_size)
      fail Validation::ValidationFailed.new({worker_size: "#{node_size.display_name} is not available for LayerRail Kubernetes on Linode"})
    end

    requested_kubernetes_vcpu_count = cp_node_count * 2 # since default control plane size is standard-2
    requested_kubernetes_vcpu_count += node_count * node_size.vcpus
    Validation.validate_vcpu_quota(@project, "KubernetesVCpu", requested_kubernetes_vcpu_count, name: :worker_nodes)

    DB.transaction do
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
        name:,
        project_id: @project.id,
        location_id: @location.id,
        cp_node_count:,
        version:,
      ).subject

      Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
        name: name + "-np",
        node_count:,
        kubernetes_cluster_id: kc.id,
        target_node_size:,
      )
      audit_log(kc, "create")

      if api?
        Serializers::KubernetesCluster.serialize(kc, {detailed: true})
      else
        flash["notice"] = "'#{name}' will be ready in a few minutes"
        request.redirect kc
      end
    end
  end

  def kubernetes_cluster_list
    raise CloverError.new(404, "NotFound", "Kubernetes is not enabled for this LayerRail deployment") unless Config.kubernetes_enabled

    dataset = @project.kubernetes_clusters_dataset
    dataset = dataset.where(location_id: @location.id) if @location
    dataset = dataset_authorize(dataset, "KubernetesCluster:view")
    if api?
      paginated_result(dataset, Serializers::KubernetesCluster)
    else
      @kcs = dataset.all.reject { it.display_state == "deleting" }
      view "kubernetes-cluster/index"
    end
  end

  def generate_kubernetes_cluster_options
    raise CloverError.new(404, "NotFound", "Kubernetes is not enabled for this LayerRail deployment") unless Config.kubernetes_enabled

    options = OptionTreeGenerator.new

    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.kubernetes_locations)
    options.add_option(name: "version", values: Option.selectable_kubernetes_versions)
    options.add_option(name: "cp_nodes", values: Option::KubernetesCPOptions.map(&:cp_node_count), parent: "location")
    options.add_option(name: "worker_size", values: Option.kubernetes_worker_size_options.map(&:display_name), parent: "location") do |location, size|
      !!Option.kubernetes_worker_size_options(location:).find { it.display_name == size }
    end
    options.add_option(name: "worker_nodes", values: (1..10).map { {value: it, display_name: "#{it} Node#{"s" unless it == 1}"} }, parent: "worker_size")

    options.serialize
  end
end
