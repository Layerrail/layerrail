# frozen_string_literal: true

class Prog::Vm::BackupPolicyNexus < Prog::Base
  subject_is :vm_backup_policy

  def self.assemble(policy)
    Strand.create_with_id(policy, prog: "Vm::BackupPolicyNexus", label: "wait", stack: [{subject_id: policy.id}])
  end

  label def wait
    nap 6 * 60 * 60 unless vm_backup_policy.enabled
    when_destroy_set? { hop_destroy }

    if vm_backup_policy.next_backup_due?
      hop_create_snapshot
    end

    prune_expired_snapshots
    nap [(vm_backup_policy.next_backup_at - Time.now).to_i, 60].max
  end

  label def create_snapshot
    snapshot = VmBackupSnapshot.create(
      vm_backup_policy_id: vm_backup_policy.id,
      vm_id: vm.id,
      provider: vm.backup_provider,
      reason: frame["reason"] || "scheduled",
      expires_at: Time.now + vm_backup_policy.retention_days * 24 * 60 * 60,
      size_gib: vm.storage_size_gib,
    )

    begin
      refs = create_provider_snapshot(snapshot)
      snapshot.update(state: "available", snapshot_refs: Sequel.pg_jsonb_wrap(refs), completed_at: Time.now)
      vm_backup_policy.update(last_backup_at: Time.now, last_error: nil)
      vm_backup_policy.schedule_next!(from: Time.now)
    rescue => ex
      snapshot.update(state: "failed", error_message: ex.message, completed_at: Time.now)
      vm_backup_policy.schedule_next!(from: Time.now, error: ex.message)
      Clog.emit("VM backup snapshot failed", Util.exception_to_hash(ex).merge(vm_id: vm.id, policy_id: vm_backup_policy.id))
    end

    hop_wait
  end

  label def destroy
    vm_backup_policy.snapshots.each { delete_snapshot(it) }
    vm_backup_policy.destroy
    pop "vm backup policy destroyed"
  end

  private

  def vm
    @vm ||= vm_backup_policy.vm
  end

  def create_provider_snapshot(snapshot)
    case snapshot.provider
    when "azure"
      create_azure_snapshots(snapshot)
    else
      fail "VM backups are not supported for #{snapshot.provider} VMs yet"
    end
  end

  def create_azure_snapshots(snapshot)
    instance = vm.azure_instance || fail("Azure instance metadata is missing")
    refs = []
    disks = [{role: "os", name: instance.os_disk_name, size_gib: vm.vm_storage_volumes.find(&:boot)&.size_gib || 0}]
    vm.vm_storage_volumes.reject(&:boot).sort_by(&:disk_index).each do |volume|
      az = volume.azure_storage_volume || next
      disks << {role: "data", name: az.disk_name, lun: az.lun, size_gib: volume.size_gib}
    end

    disks.each do |disk|
      snapshot_name = azure_snapshot_name(snapshot.id, disk[:role], disk[:lun])
      source_disk_id = azure.resource_id(instance.resource_group, "Microsoft.Compute/disks", disk[:name])
      azure.create_snapshot(
        resource_group: instance.resource_group,
        region: instance.region,
        name: snapshot_name,
        source_disk_id:,
        tags: {
          "LayerRail" => "true",
          "Project" => vm.project.ubid,
          "VM" => vm.ubid,
          "Backup" => snapshot.id.to_s,
          "DiskRole" => disk[:role],
        },
      )
      refs << disk.merge(provider_snapshot_name: snapshot_name, provider_snapshot_id: azure.resource_id(instance.resource_group, "Microsoft.Compute/snapshots", snapshot_name))
    end
    refs
  rescue AzureAPIError => ex
    raise if !ex.retryable_create?

    Clog.emit("Azure VM backup waiting on snapshot create", {azure_vm_backup_waiting: {vm_ubid: vm.ubid, status: ex.status, body: ex.body}})
    nap 30
  end

  def prune_expired_snapshots
    vm_backup_policy.snapshots_dataset.where { (state =~ "available") & (expires_at < Time.now) }.all.each do |snapshot|
      delete_snapshot(snapshot)
    end
  end

  def delete_snapshot(snapshot)
    snapshot.update(state: "deleting") if snapshot.state != "deleting"
    case snapshot.provider
    when "azure"
      instance = vm.azure_instance
      Array(snapshot.snapshot_refs).each do |ref|
        azure.delete_snapshot(instance.resource_group, ref["provider_snapshot_name"]) if instance && ref["provider_snapshot_name"]
      end
    end
    snapshot.destroy
  rescue AzureAPIError => ex
    return if ex.not_found?
    raise unless ex.retryable_delete?

    nap 30
  end

  def azure_snapshot_name(snapshot_id, role, lun)
    suffix = [snapshot_id, role, lun].compact.join("-")
    "lr-snap-#{vm.ubid}-#{suffix}".downcase.gsub(/[^a-z0-9-]/, "-")[0, 80].delete_suffix("-")
  end

  def azure
    @azure ||= AzureClient.new
  end
end
