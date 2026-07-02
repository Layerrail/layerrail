# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "vm") do |r|
    r.get api? do
      vm_list
    end

    r.on VM_NAME_OR_UBID do |vm_name, vm_id|
      if vm_name
        r.post api? do
          check_visible_location
          vm_post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => vm_id}
      end

      filter[:location_id] = @location.id
      vm = @vm = @project.vms_dataset.first(filter)
      check_found_object(vm)

      r.get true do
        authorize("Vm:view", vm)

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          r.redirect vm, "/overview"
        end
      end

      r.delete true do
        authorize("Vm:delete", vm)

        DB.transaction do
          BillingRecord.finalize_active_for_resource(vm)
          vm.incr_destroy
          audit_log(vm, "destroy")
        end

        if web?
          flash["notice"] = "Virtual machine scheduled for deletion."
          r.redirect @project, "/vm"
        else
          204
        end
      end

      r.rename vm, perm: "Vm:edit", serializer: Serializers::Vm, template_prefix: "vm"

      r.show_object(vm, actions: %w[overview networking backups settings], perm: "Vm:view", template: "vm/show")

      r.post web?, "backups" do
        authorize("Vm:edit", vm)
        handle_validation_failure("vm/show") { @page = "backups" }

        schedule_hours = typecast_params.pos_int("schedule_hours") || 24
        retention_days = typecast_params.pos_int("retention_days") || 7
        enabled = typecast_params.bool("enabled")

        unless [6, 12, 24, 168].include?(schedule_hours)
          raise_web_error("Choose a valid backup schedule.")
        end

        unless (1..90).cover?(retention_days)
          raise_web_error("Retention must be between 1 and 90 days.")
        end

        DB.transaction do
          policy = vm.vm_backup_policy || VmBackupPolicy.create(vm_id: vm.id)
          policy.update(enabled:, schedule_hours:, retention_days:, updated_at: Time.now)
          Prog::Vm::BackupPolicyNexus.assemble(policy) unless policy.strand
          audit_log(vm, "update_backup_policy")
        end

        flash["notice"] = "Backup policy updated."
        r.redirect vm, "/backups"
      end

      r.post web?, "backups/create" do
        authorize("Vm:edit", vm)
        handle_validation_failure("vm/show") { @page = "backups" }

        policy = nil
        DB.transaction do
          policy = vm.vm_backup_policy || VmBackupPolicy.create(vm_id: vm.id)
          Strand.create(prog: "Vm::BackupPolicyNexus", label: "create_snapshot", stack: [{subject_id: policy.id, reason: "manual"}])
          audit_log(vm, "create_backup")
        end

        flash["notice"] = "Backup snapshot started."
        r.redirect vm, "/backups"
      end

      r.post %w[restart start stop] do |action|
        authorize("Vm:edit", vm)
        handle_validation_failure("vm/show") { @page = "settings" }

        unless ["metal", "linode"].include?(vm.location.provider_dispatcher_group_name)
          raise CloverError.new(400, "InvalidRequest", "The #{action} action is not supported for VMs running on #{vm.location.ui_name}")
        end

        unless vm.send(:"can_#{action}?")
          raise CloverError.new(400, "InvalidRequest", "The #{action} action is not supported in the VM's current state")
        end

        DB.transaction do
          vm.public_send(:"incr_#{action}")
          audit_log(vm, action)
        end

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          notice = "Scheduled #{action} of #{vm.name}"
          if action == "stop"
            notice << ". Note that stopped VMs still accrue billing charges. To stop billing charges, delete the VM."
          end
          flash["notice"] = notice
          r.redirect vm, "/settings"
        end
      end
    end
  end
end
