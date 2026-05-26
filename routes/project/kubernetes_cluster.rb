# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "kubernetes-cluster") do |r|
    r.get true do
      kubernetes_cluster_list
    end

    r.web do
      r.post true do
        handle_validation_failure("kubernetes-cluster/create")
        check_visible_location
        kubernetes_cluster_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        raise CloverError.new(404, "NotFound", "Kubernetes is not enabled for this LayerRail deployment") unless Config.kubernetes_enabled

        authorize("KubernetesCluster:create", @project)
        view "kubernetes-cluster/create"
      end
    end
  end
end
