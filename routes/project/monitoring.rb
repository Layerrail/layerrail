# frozen_string_literal: true

require "uri"

class Clover
  hash_branch(:project_prefix, "monitoring") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        load_monitoring_index
        view "monitoring/index"
      end

      r.on "uptime" do
        r.get "create" do
          authorize("Project:billing", @project)
          view "monitoring/uptime_create"
        end

        r.post true do
          authorize("Project:billing", @project)
          handle_validation_failure("monitoring/uptime_create")
          name = typecast_params.nonempty_str!("name").downcase
          Validation.validate_name(name)
          raise_web_error("An uptime check named #{name} already exists.") if @project.uptime_checks_dataset.where(name:).count.positive?

          target_url = normalize_monitoring_url(typecast_params.nonempty_str!("target_url"))
          method = typecast_params.nonempty_str("method") || "GET"
          raise_web_error("Method must be GET or HEAD.") unless %w[GET HEAD].include?(method)

          check = nil
          DB.transaction do
            check = UptimeCheck.create(
              project_id: @project.id,
              name:,
              target_url:,
              method:,
              expected_status: typecast_params.pos_int("expected_status") || 200,
              interval_seconds: typecast_params.pos_int("interval_seconds") || 60,
              timeout_seconds: typecast_params.pos_int("timeout_seconds") || 10,
            )
            Prog::Monitoring::UptimeCheckNexus.assemble(check)
            audit_log(check, "create")
          end
          flash["notice"] = "Uptime check #{check.name} is active."
          r.redirect "#{@project.path}#{check.path}"
        end

        r.on String do |name|
          @uptime_check = check = @project.uptime_checks_dataset.first(name:)
          check_found_object(check)

          r.get true do
            @incidents = check.monitoring_incidents_dataset.reverse(:opened_at).limit(20).all
            @alerts = check.monitoring_alerts_dataset.order(:name).all
            view "monitoring/uptime_show"
          end

          r.post "run" do
            authorize("Project:billing", @project)
            check.run_check!
            check.evaluate_alerts!
            flash["notice"] = "Uptime check #{check.name} ran. Current state: #{check.state}."
            r.redirect "#{@project.path}#{check.path}"
          end

          r.post "pause" do
            authorize("Project:billing", @project)
            check.update(enabled: false, state: "paused", updated_at: Time.now)
            flash["notice"] = "Uptime check #{check.name} paused."
            r.redirect "#{@project.path}#{check.path}"
          end

          r.post "resume" do
            authorize("Project:billing", @project)
            check.update(enabled: true, state: "pending", updated_at: Time.now)
            check.strand&.update(schedule: Time.now, lease: Time.now - 1, try: 0)
            flash["notice"] = "Uptime check #{check.name} resumed."
            r.redirect "#{@project.path}#{check.path}"
          end

          r.delete true do
            authorize("Project:billing", @project)
            DB.transaction do
              check.incr_destroy
              audit_log(check, "destroy")
            end
            flash["notice"] = "Uptime check #{check.name} scheduled for deletion."
            r.redirect "#{@project.path}/monitoring"
          end
        end
      end

      r.on "alerts" do
        r.get "create" do
          authorize("Project:billing", @project)
          @uptime_checks = @project.uptime_checks_dataset.order(:name).all
          @channels = @project.monitoring_notification_channels_dataset.where(enabled: true).order(:name).all
          view "monitoring/alert_create"
        end

        r.post true do
          authorize("Project:billing", @project)
          handle_validation_failure("monitoring/alert_create")
          name = typecast_params.nonempty_str!("name").downcase
          Validation.validate_name(name)
          raise_web_error("An alert named #{name} already exists.") if @project.monitoring_alerts_dataset.where(name:).count.positive?

          uptime_check = @project.uptime_checks_dataset[id: typecast_params.nonempty_str("uptime_check_id")]
          channel = @project.monitoring_notification_channels_dataset[id: typecast_params.nonempty_str("notification_channel_id")]

          alert = MonitoringAlert.create(
            project_id: @project.id,
            uptime_check_id: uptime_check&.id,
            notification_channel_id: channel&.id,
            name:,
            resource_type: typecast_params.nonempty_str("resource_type") || "uptime",
            condition: typecast_params.nonempty_str("condition") || "down",
            threshold: typecast_params.pos_int("threshold"),
            severity: typecast_params.nonempty_str("severity") || "warning",
          )
          alert.ensure_billing_record!
          audit_log(alert, "create")
          flash["notice"] = "Alert #{alert.name} created."
          r.redirect "#{@project.path}#{alert.path}"
        end

        r.on String do |name|
          @alert = alert = @project.monitoring_alerts_dataset.first(name:)
          check_found_object(alert)

          r.get true do
            @incidents = alert.monitoring_incidents_dataset.reverse(:opened_at).limit(20).all
            view "monitoring/alert_show"
          end

          r.post "toggle" do
            authorize("Project:billing", @project)
            alert.update(enabled: !alert.enabled, updated_at: Time.now)
            flash["notice"] = "Alert #{alert.name} #{alert.enabled ? "enabled" : "disabled"}."
            r.redirect "#{@project.path}#{alert.path}"
          end

          r.delete true do
            authorize("Project:billing", @project)
            BillingRecord.finalize_active_for_resource(alert)
            alert.destroy
            flash["notice"] = "Alert #{alert.name} deleted."
            r.redirect "#{@project.path}/monitoring"
          end
        end
      end

      r.on "incidents" do
        r.on String do |ubid|
          @incident = incident = @project.monitoring_incidents_dataset.all.find { it.ubid == ubid }
          check_found_object(incident)

          r.get true do
            view "monitoring/incident_show"
          end

          r.post "acknowledge" do
            authorize("Project:billing", @project)
            incident.acknowledge!
            flash["notice"] = "Incident acknowledged."
            r.redirect "#{@project.path}#{incident.path}"
          end

          r.post "resolve" do
            authorize("Project:billing", @project)
            incident.resolve!
            flash["notice"] = "Incident resolved."
            r.redirect "#{@project.path}#{incident.path}"
          end
        end
      end

      r.on "notification-channels" do
        r.get "create" do
          authorize("Project:billing", @project)
          view "monitoring/channel_create"
        end

        r.post true do
          authorize("Project:billing", @project)
          handle_validation_failure("monitoring/channel_create")
          name = typecast_params.nonempty_str!("name").downcase
          Validation.validate_name(name)
          kind = typecast_params.nonempty_str("kind") || "email"
          target = typecast_params.nonempty_str!("target").strip
          raise_web_error("Channel type must be email or webhook.") unless %w[email webhook].include?(kind)
          target = Validation.validate_public_http_url(target, field: :target) if kind == "webhook"
          raise_web_error("A notification channel named #{name} already exists.") if @project.monitoring_notification_channels_dataset.where(name:).count.positive?

          channel = MonitoringNotificationChannel.create(project_id: @project.id, name:, kind:, target:)
          audit_log(channel, "create")
          flash["notice"] = "Notification channel #{channel.name} created."
          r.redirect "#{@project.path}#{channel.path}"
        end

        r.on String do |name|
          @channel = channel = @project.monitoring_notification_channels_dataset.first(name:)
          check_found_object(channel)

          r.get true do
            @alerts = channel.monitoring_alerts_dataset.order(:name).all
            view "monitoring/channel_show"
          end

          r.post "test" do
            authorize("Project:billing", @project)
            channel.deliver_test!
            flash["notice"] = "Test notification sent to #{channel.name}."
            r.redirect "#{@project.path}#{channel.path}"
          end

          r.post "toggle" do
            authorize("Project:billing", @project)
            channel.update(enabled: !channel.enabled, updated_at: Time.now)
            flash["notice"] = "Notification channel #{channel.name} #{channel.enabled ? "enabled" : "disabled"}."
            r.redirect "#{@project.path}#{channel.path}"
          end

          r.delete true do
            authorize("Project:billing", @project)
            channel.destroy
            flash["notice"] = "Notification channel #{channel.name} deleted."
            r.redirect "#{@project.path}/monitoring"
          end
        end
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

  def load_monitoring_index
    @metrics_resources = @project.victoria_metrics_resources_dataset.eager(:location, :servers).reverse(:created_at).all
    @log_resources = @project.parseable_resources_dataset.eager(:location, :servers).reverse(:created_at).all
    @uptime_checks = @project.uptime_checks_dataset.reverse(:created_at).all
    @alerts = @project.monitoring_alerts_dataset.eager(:uptime_check, :notification_channel).order(:name).all
    @incidents = @project.monitoring_incidents_dataset.reverse(:opened_at).limit(20).all
    @channels = @project.monitoring_notification_channels_dataset.order(:name).all
  end

  def normalize_monitoring_url(raw)
    Validation.validate_public_http_url(raw.strip, allowed_schemes: %w[http https], field: :target_url)
  end
end
