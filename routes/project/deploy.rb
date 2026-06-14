# frozen_string_literal: true

require "securerandom"
require "uri"

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

    r.on web?, "github" do
      authorize("Vm:create", @project)

      r.get "create" do
        load_deploy_form_options
        handle_validation_failure("deploy/create")
        raise_web_error("Project doesn't have valid billing information") unless @project.has_valid_payment_method?
        raise_web_error("GitHub App is not configured yet.") unless Config.github_app_name

        session["github_installation_project_id"] = @project.id
        session["github_installation_context"] = "deploy"
        state = SecureRandom.urlsafe_base64(24)
        session["github_installation_state"] = state

        query = URI.encode_www_form(state:)
        r.redirect "https://github.com/apps/#{Config.github_app_name}/installations/select_target?#{query}", 302
      end

      r.get "finish" do
        load_deploy_form_options
        handle_validation_failure("deploy/create")
        raise_web_error("GitHub App OAuth client ID is not configured") unless Config.github_app_client_id
        raise_web_error("Project doesn't have valid billing information") unless @project.has_valid_payment_method?

        session["github_installation_project_id"] = @project.id
        session["github_installation_context"] = "deploy"
        state = SecureRandom.urlsafe_base64(24)
        session["github_installation_state"] = state

        query = URI.encode_www_form(
          client_id: Config.github_app_client_id,
          redirect_uri: "#{Config.base_url}/github/callback",
          state:
        )
        r.redirect "https://github.com/login/oauth/authorize?#{query}", 302
      end
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
      framework = "auto" if framework.empty?
      vm_size = Config.deploy_infrastructure_controls_enabled ? typecast_params.str("vm_size").to_s.strip : ""
      vm_size = Config.deploy_default_vm_size if vm_size.empty?

      Validation.validate_name(name)
      build_params = {
        install_command: typecast_params.str("install_command").to_s.strip,
        build_command: blank_to_nil(typecast_params.str("build_command")),
        start_command: blank_to_nil(typecast_params.str("start_command")),
        output_directory: blank_to_nil(typecast_params.str("output_directory")),
        app_port: typecast_params.pos_int("app_port")
      }
      framework = detect_deploy_framework(installation, repository, branch, typecast_params.str("root_directory").to_s.strip) if framework == "auto"
      build_params = DeployApp.apply_build_pack_defaults(build_params, framework)

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
          install_command: build_params[:install_command].to_s,
          build_command: blank_to_nil(build_params[:build_command]),
          start_command: blank_to_nil(build_params[:start_command]),
          output_directory: blank_to_nil(build_params[:output_directory]),
          app_port: build_params[:app_port] || Config.deploy_default_port,
          framework: build_params[:framework],
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
        load_deploy_show_data("overview")
        view "deploy/show"
      end

      r.get "deployments" do
        load_deploy_show_data("deployments")
        view "deploy/show"
      end

      r.get "domains" do
        load_deploy_show_data("domains")
        view "deploy/show"
      end

      r.get "environment" do
        load_deploy_show_data("environment")
        view "deploy/show"
      end

      r.get "settings" do
        load_deploy_show_data("settings")
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

      r.post "rollback", :ubid_uuid do |deployment_id|
        authorize("Vm:create", @project)
        deployment = @deploy_app.deployments_dataset.first(id: deployment_id)
        check_found_object(deployment)
        raise_web_error("This deployment does not have an image to roll back to.") if deployment.image_ref.to_s.empty?
        in_flight = @deploy_app.latest_deployment&.status
        raise_web_error("A deployment is already running.") if %w[queued provisioning building].include?(in_flight)

        DB.transaction do
          Prog::Deploy::DeploymentNexus.assemble(
            @deploy_app,
            trigger: "rollback",
            commit_sha: deployment.commit_sha,
            commit_message: "Rollback to #{deployment.ubid}",
            image_ref: deployment.image_ref
          )
          audit_log(@deploy_app, "rollback")
        end
        flash["notice"] = "Rollback started"
        r.redirect "#{path(@deploy_app)}/deployments"
      end

      r.post "domain" do
        authorize("Project:billing", @project)
        action = typecast_params.str("action").to_s
        domain_id = typecast_params.nonempty_str!("domain_registration_id")
        domain_registration = @project.domain_registrations_dataset.first(id: UBID.to_uuid(domain_id))
        check_found_object(domain_registration)
        raise_web_error("This domain must be active before it can be attached to a deploy app.") unless domain_registration.active?

        DB.transaction do
          if action == "detach"
            raise_web_error("This domain is not attached to this deploy app.") unless domain_registration.deploy_app_id == @deploy_app.id
            domain_registration.detach_from_deploy_app!
            audit_log(domain_registration, "detach_deploy_app")
            flash["notice"] = "#{domain_registration.domain} detached from #{@deploy_app.name}."
          else
            domain_registration.attach_to_deploy_app!(@deploy_app)
            audit_log(domain_registration, "attach_deploy_app")
            flash["notice"] = "#{domain_registration.domain} attached to #{@deploy_app.name}."
          end
        end
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

      r.post "settings" do
        load_deploy_show_data("settings")
        handle_validation_failure("deploy/show")
        authorize("Vm:create", @project)
        framework = typecast_params.str("framework").to_s.strip
        framework = @deploy_app.framework if framework.empty?
        app_port = typecast_params.pos_int("app_port") || @deploy_app.app_port
        updates = {
          branch: blank_to_nil(typecast_params.str("branch")) || @deploy_app.branch,
          root_directory: typecast_params.str("root_directory").to_s.strip,
          install_command: typecast_params.str("install_command").to_s.strip,
          build_command: blank_to_nil(typecast_params.str("build_command")),
          start_command: blank_to_nil(typecast_params.str("start_command")),
          output_directory: blank_to_nil(typecast_params.str("output_directory")),
          app_port:,
          framework:,
          auto_deploy: typecast_params.bool("auto_deploy"),
          build_cache_enabled: typecast_params.bool("build_cache_enabled")
        }

        DB.transaction do
          @deploy_app.update(updates.merge(updated_at: Time.now))
          audit_log(@deploy_app, "update_settings")
        end
        flash["notice"] = "Deploy settings saved"
        r.redirect "#{path(@deploy_app)}/settings"
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
    @deploy_repositories = @github_installations.flat_map { deploy_repositories_for(it) }
    locations = Location.visible_or_for_project(@project.id, @project.get_ff_visible_locations)
      .where(visible: true)
      .order(:ui_name)
      .all
    @deploy_locations = Config.compute_provider ? locations.select { it.provider == Config.compute_provider } : locations
    @deploy_vm_sizes = DeployApp.vm_size_options
  end

  def load_deploy_show_data(tab)
    @deploy_tab = tab
    case tab
    when "deployments"
      @deployments = @deploy_app.deployments_dataset.limit(20).all
    when "domains"
      @deploy_domains = @project.domain_registrations_dataset.where(deploy_app_id: @deploy_app.id).order(:domain).all
      @available_domains = @project.domain_registrations_dataset.where(status: "active", deploy_app_id: nil).order(:domain).all
    end
  end

  def deploy_repositories_for(installation)
    response = installation.client(auto_paginate: true, per_page: 100).get("/installation/repositories")
    repos = response[:repositories] || response["repositories"] || (response.repositories if response.respond_to?(:repositories)) || []
    repos.filter_map do |repo|
      repo_hash = repo.respond_to?(:to_h) ? repo.to_h : repo
      full_name = repo_hash[:full_name] || repo_hash["full_name"] || (repo.full_name if repo.respond_to?(:full_name))
      name = repo_hash[:name] || repo_hash["name"] || (repo.name if repo.respond_to?(:name))
      default_branch = repo_hash[:default_branch] || repo_hash["default_branch"] || (repo.default_branch if repo.respond_to?(:default_branch))
      private_repo = repo_hash.respond_to?(:key?) && repo_hash.key?(:private) ? repo_hash[:private] : repo_hash["private"]
      updated_at = repo_hash[:updated_at] || repo_hash["updated_at"] || (repo.updated_at if repo.respond_to?(:updated_at))
      next if full_name.to_s.empty?

      {
        installation_ubid: installation.ubid,
        installation_label: "#{installation.name} (#{installation.type})",
        full_name: full_name.to_s,
        name: name.to_s.empty? ? full_name.to_s.split("/").last : name.to_s,
        private: private_repo.nil? ? nil : !!private_repo,
        default_branch: default_branch.to_s.empty? ? "main" : default_branch.to_s,
        updated_at:
      }
    end
  rescue => ex
    Clog.emit("deploy repository list failed", Util.exception_to_hash(ex, into: {deploy_repository_list_failed: {installation_ubid: installation.ubid}}))
    installation.repositories_dataset.order(:name).limit(100).all.map do |repo|
      {
        installation_ubid: installation.ubid,
        installation_label: "#{installation.name} (#{installation.type})",
        full_name: repo.name,
        name: repo.repository_name,
        private: nil,
        default_branch: repo.default_branch.to_s.empty? ? "main" : repo.default_branch,
        updated_at: repo.last_job_at
      }
    end
  end

  def detect_deploy_framework(installation, repository, branch, root_directory)
    path = "/repos/#{repository}/contents"
    path = "#{path}/#{root_directory}" unless root_directory.to_s.empty?
    response = installation.client(auto_paginate: true, per_page: 100).get(path, ref: branch)
    items = Array(response)
    files = items.filter_map do |item|
      item_hash = item.respond_to?(:to_h) ? item.to_h : item
      type = item_hash[:type] || item_hash["type"] || (item.type if item.respond_to?(:type))
      name = item_hash[:name] || item_hash["name"] || (item.name if item.respond_to?(:name))
      name.to_s if type.to_s == "file" && !name.to_s.empty?
    end
    DeployApp.detect_framework(files)
  rescue => ex
    Clog.emit("deploy framework detection failed", Util.exception_to_hash(ex, into: {deploy_framework_detection_failed: {repository:, branch:}}))
    "node"
  end
end
