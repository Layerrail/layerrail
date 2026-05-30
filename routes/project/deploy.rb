# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "deploy") do |r|
    raise CloverError.new(404, "NotFound", "LayerRail Deploy is not enabled") unless Config.deploy_enabled

    r.get true do
      @deploy_apps = dataset_authorize(@project.deploy_apps_dataset.reverse(:created_at), "Vm:view").all
      view "deploy/index"
    end

    r.get "create" do
      authorize("Vm:create", @project)
      load_deploy_form_options
      view "deploy/create"
    end

    r.post true do
      handle_validation_failure("deploy/create")
      authorize("Vm:create", @project)
      load_deploy_form_options

      raise_web_error("Billing verification is required before creating a deploy app.") unless @project.has_valid_payment_method?
      unless Config.github_app_name && Config.github_app_id && Config.github_app_private_key
        raise_web_error("GitHub App is not fully configured yet.")
      end

      installation_id = typecast_params.ubid_uuid("installation_id")
      installation = @project.github_installations_dataset.first(id: installation_id)
      raise_web_error("Select a connected GitHub account.") unless installation

      if Config.deploy_infrastructure_controls_enabled
        check_visible_location
      else
        @location = @deploy_locations.first
        raise_web_error("LayerRail Deploy does not have an available runtime location yet.") unless @location
      end
      if Config.compute_provider && @location.provider != Config.compute_provider
        fail Validation::ValidationFailed.new({location: "LayerRail Deploy is configured for #{Config.compute_provider}, but #{@location.ui_name} uses #{@location.provider}."})
      end

      name = typecast_params.nonempty_str!("name")
      repository = typecast_params.nonempty_str!("repository")
      branch = typecast_params.str("branch").to_s.strip
      branch = "main" if branch.empty?
      framework = typecast_params.str("framework").to_s.strip
      framework = "node" if framework.empty?
      vm_size = Config.deploy_infrastructure_controls_enabled ? typecast_params.str("vm_size").to_s.strip : ""
      vm_size = Config.deploy_default_vm_size if vm_size.empty?

      Validation.validate_name(name)
      unless DeployApp.vm_size_available?(vm_size)
        fail Validation::ValidationFailed.new({vm_size: "is not available for LayerRail Deploy"})
      end
      vm_size_info = Validation.validate_vm_size(vm_size, "x64", only_visible: true)
      Validation.validate_vcpu_quota(@project, "VmVCpu", vm_size_info.vcpus)

      app = nil
      DB.transaction do
        app = DeployApp.new_with_id(
          project_id: @project.id,
          installation_id: installation.id,
          location_id: @location.id,
          name:,
          repository:,
          branch:,
          root_directory: typecast_params.str("root_directory").to_s.strip,
          install_command: typecast_params.str("install_command").to_s.strip,
          build_command: blank_to_nil(typecast_params.str("build_command")),
          start_command: blank_to_nil(typecast_params.str("start_command")),
          output_directory: blank_to_nil(typecast_params.str("output_directory")),
          app_port: typecast_params.pos_int("app_port") || Config.deploy_default_port,
          framework:,
          vm_size:,
          status: "provisioning",
        )
        app.hostname = "#{app.name}-#{app.ubid.to_s[2, 6]}.#{Config.deploy_service_hostname}"
        app.save_changes
        Prog::Deploy::DeploymentNexus.assemble(app)
        audit_log(app, "create")
      end

      flash["notice"] = "LayerRail Deploy app is being provisioned"
      r.redirect path(app)
    end

    show_deploy_app = lambda do |name, id|
      matched_id = id || (UBID.to_uuid(name) if name)
      @deploy_app = matched_id ? @project.deploy_apps_dataset.first(id: matched_id) : @project.deploy_apps_dataset.first(name:)
      check_found_object(@deploy_app)
      authorize("Vm:view", @project)

      r.get true do
        @deployments = @deploy_app.deployments_dataset.limit(10).all
        view "deploy/show"
      end

      r.post "deploy" do
        authorize("Vm:create", @project)
        in_flight = @deploy_app.latest_deployment&.status
        raise_web_error("A deployment is already running.") if %w[queued provisioning building].include?(in_flight)

        DB.transaction do
          Prog::Deploy::DeploymentNexus.assemble(@deploy_app)
          audit_log(@deploy_app, "deploy")
        end
        flash["notice"] = "Deployment started"
        r.redirect path(@deploy_app)
      end

      r.post "variable" do
        authorize("Vm:create", @project)
        key = typecast_params.nonempty_str!("key").strip.upcase
        value = typecast_params.str("value").to_s

        DB.transaction do
          if (variable = @deploy_app.variables_dataset.first(key:))
            variable.update(value:, updated_at: Time.now)
          else
            DeployVariable.create(app_id: @deploy_app.id, key:, value:)
          end
          audit_log(@deploy_app, "update_variable")
        end
        flash["notice"] = "Environment variable saved"
        r.redirect path(@deploy_app)
      end

      r.post "variable-delete", :ubid_uuid do |variable_id|
        authorize("Vm:create", @project)
        variable = @deploy_app.variables_dataset.first(id: variable_id)
        check_found_object(variable)
        DB.transaction do
          variable.destroy
          audit_log(@deploy_app, "delete_variable")
        end
        flash["notice"] = "Environment variable deleted"
        r.redirect path(@deploy_app)
      end

      r.post "delete" do
        authorize("Vm:delete", @project)
        DB.transaction do
          Prog::Deploy::AppNexus.assemble_destroy(@deploy_app)
          audit_log(@deploy_app, "destroy")
        end
        flash["notice"] = "Deploy app deletion started"
        r.redirect "#{@project.path}/deploy"
      end
    end

    r.on :ubid_uuid do |id|
      show_deploy_app.call(nil, id)
    end

    r.on /([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)/ do |name|
      show_deploy_app.call(name, nil)
    end
  end

  def blank_to_nil(value)
    value = value.to_s.strip
    value.empty? ? nil : value
  end

  def load_deploy_form_options
    @github_installations = @project.github_installations_dataset.order(:name).all
    locations = Location.visible_or_for_project(@project.id, @project.get_ff_visible_locations)
      .where(visible: true)
      .order(:ui_name)
      .all
    @deploy_locations = Config.compute_provider ? locations.select { it.provider == Config.compute_provider } : locations
    @deploy_vm_sizes = DeployApp.vm_size_options
  end
end
