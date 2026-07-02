# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "edge") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        @edge_services = @project.edge_services_dataset.reverse(:created_at).all
        view "edge/index"
      end

      r.get "create" do
        authorize("Project:billing", @project)
        view "edge/create"
      end

      r.post true do
        authorize("Project:billing", @project)
        handle_validation_failure("edge/create")
        name = typecast_params.nonempty_str!("name").downcase
        Validation.validate_name(name)
        origin_url = typecast_params.nonempty_str!("origin_url").strip
        cache_mode = typecast_params.nonempty_str("cache_mode") || "standard"
        tls_mode = typecast_params.nonempty_str("tls_mode") || "full"
        raise_web_error("Origin must start with http:// or https://") unless origin_url.match?(%r{\Ahttps?://}i)
        raise_web_error("Choose a valid cache mode.") unless EdgeService::CACHE_MODES.key?(cache_mode)
        raise_web_error("Choose a valid TLS mode.") unless EdgeService::TLS_MODES.key?(tls_mode)
        raise_web_error("An edge service named #{name} already exists.") if @project.edge_services_dataset.where(name:).count.positive?

        edge_service = nil
        DB.transaction do
          edge_service = EdgeService.create(
            project_id: @project.id,
            name:,
            hostname: EdgeService.generate_hostname(@project, name),
            origin_url:,
            cache_mode:,
            tls_mode:
          )
          Prog::EdgeServiceNexus.assemble(edge_service)
          audit_log(edge_service, "create")
        end

        flash["notice"] = "Edge service #{name} is being created."
        r.redirect "#{@project.path}#{edge_service.path}"
      end

      r.on String do |name|
        @edge_service = edge_service = @project.edge_services_dataset.first(name:)
        check_found_object(edge_service)

        r.get true do
          view "edge/show"
        end

        r.post "delete" do
          authorize("Project:billing", @project)
          DB.transaction do
            edge_service.incr_destroy
            audit_log(edge_service, "destroy")
          end
          flash["notice"] = "Edge service #{edge_service.name} scheduled for deletion."
          r.redirect "#{@project.path}/edge"
        end
      end
    end
  end
end
