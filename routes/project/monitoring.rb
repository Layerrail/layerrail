# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "monitoring") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        @metrics_resources = @project.victoria_metrics_resources_dataset.eager(:location, :servers).reverse(:created_at).all
        @log_resources = @project.parseable_resources_dataset.eager(:location, :servers).reverse(:created_at).all
        view "monitoring/index"
      end

      r.on "metrics" do
        r.get "create" do
          authorize("Project:billing", @project)
          @locations = VictoriaMetricsResource.available_locations
          view "monitoring/metrics_create"
        end

        r.post true do
          authorize("Project:billing", @project)
          handle_validation_failure("monitoring/metrics_create")
          name = typecast_params.nonempty_str!("name").downcase
          Validation.validate_name(name)
          location = Location[typecast_params.nonempty_str!("location_id")]
          check_found_object(location)
          raise_web_error("Metrics is not available in #{location.ui_name}.") unless VictoriaMetricsResource.available_locations.map(&:id).include?(location.id)
          raise_web_error("A metrics backend named #{name} already exists.") if @project.victoria_metrics_resources_dataset.where(name:).count.positive?

          storage_size_gib = typecast_params.pos_int("storage_size_gib") || 100
          resource = nil
          DB.transaction do
            strand = Prog::VictoriaMetrics::VictoriaMetricsResourceNexus.assemble(
              @project.id,
              name,
              location.id,
              "metrics_admin",
              typecast_params.nonempty_str("vm_size") || "standard-2",
              storage_size_gib,
            )
            resource = strand.subject
            audit_log(resource, "create")
          end

          flash["notice"] = "Metrics backend #{name} is being created."
          r.redirect "#{@project.path}#{resource.path}"
        end

        r.on String do |name|
          @metrics_resource = resource = @project.victoria_metrics_resources_dataset.first(name:)
          check_found_object(resource)

          r.get true do
            view "monitoring/metrics_show"
          end

          r.post "retry" do
            authorize("Project:billing", @project)
            DB.transaction do
              if (strand = resource.strand)
                strand.update(label: "wait_servers", lease: Time.now - 1000 * 365 * 24 * 60 * 60, schedule: Time.now, try: 0)
              else
                Prog::VictoriaMetrics::VictoriaMetricsResourceNexus.assemble(resource.project_id, resource.name, resource.location_id, resource.admin_user, resource.target_vm_size, resource.target_storage_size_gib)
              end
              resource.servers.each(&:incr_reconfigure)
              audit_log(resource, "retry")
            end
            flash["notice"] = "Metrics backend #{resource.name} retry started."
            r.redirect "#{@project.path}#{resource.path}"
          end

          r.post "delete" do
            authorize("Project:billing", @project)
            DB.transaction do
              resource.incr_destroy
              audit_log(resource, "destroy")
            end
            flash["notice"] = "Metrics backend #{resource.name} scheduled for deletion."
            r.redirect "#{@project.path}/monitoring"
          end
        end
      end

      r.on "logs" do
        r.get "create" do
          authorize("Project:billing", @project)
          @locations = ParseableResource.available_locations
          view "monitoring/logs_create"
        end

        r.post true do
          authorize("Project:billing", @project)
          handle_validation_failure("monitoring/logs_create")
          name = typecast_params.nonempty_str!("name").downcase
          Validation.validate_name(name)
          location = Location[typecast_params.nonempty_str!("location_id")]
          check_found_object(location)
          raise_web_error("Logs is not available in #{location.ui_name}.") unless ParseableResource.available_locations.map(&:id).include?(location.id)
          raise_web_error("A logs backend named #{name} already exists.") if @project.parseable_resources_dataset.where(name:).count.positive?

          storage_size_gib = typecast_params.pos_int("storage_size_gib") || 100
          resource = nil
          DB.transaction do
            strand = Prog::Parseable::ParseableResourceNexus.assemble(
              project_id: @project.id,
              name:,
              location_id: location.id,
              admin_user: "logs_admin",
              vm_size: typecast_params.nonempty_str("vm_size") || "standard-2",
              storage_size_gib:,
            )
            resource = strand.subject
            audit_log(resource, "create")
          end

          flash["notice"] = "Logs backend #{name} is being created."
          r.redirect "#{@project.path}#{resource.path}"
        end

        r.on String do |name|
          @log_resource = resource = @project.parseable_resources_dataset.first(name:)
          check_found_object(resource)

          r.get true do
            view "monitoring/logs_show"
          end

          r.post "retry" do
            authorize("Project:billing", @project)
            DB.transaction do
              if (strand = resource.strand)
                strand.update(label: "configure_blob_storage", lease: Time.now - 1000 * 365 * 24 * 60 * 60, schedule: Time.now, try: 0)
              else
                Prog::Parseable::ParseableResourceNexus.assemble(project_id: resource.project_id, name: resource.name, location_id: resource.location_id, admin_user: resource.admin_user, vm_size: resource.target_vm_size, storage_size_gib: resource.target_storage_size_gib)
              end
              resource.servers.each(&:incr_reconfigure)
              audit_log(resource, "retry")
            end
            flash["notice"] = "Logs backend #{resource.name} retry started."
            r.redirect "#{@project.path}#{resource.path}"
          end

          r.post "delete" do
            authorize("Project:billing", @project)
            DB.transaction do
              resource.incr_destroy
              audit_log(resource, "destroy")
            end
            flash["notice"] = "Logs backend #{resource.name} scheduled for deletion."
            r.redirect "#{@project.path}/monitoring"
          end
        end
      end
    end
  end
end
