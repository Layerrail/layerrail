# frozen_string_literal: true

class Prog::BlockVolumeNexus < Prog::Base
  subject_is :block_volume

  def self.assemble(block_volume)
    Strand.create_with_id(block_volume, prog: "BlockVolumeNexus", label: "start", stack: [{subject_id: block_volume.id}])
  end

  label def start
    when_destroy_set? { hop_destroy }
    create_provider_volume unless block_volume.provider_volume_id
    block_volume.ensure_billing_record!
    block_volume.update(state: "available", last_error: nil, updated_at: Time.now)
    hop_wait
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    block_volume.update(state: "failed", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Block volume provision failed", Util.exception_to_hash(ex).merge(block_volume_id: block_volume.id))
    nap 30 * 60
  end

  label def wait
    when_destroy_set? { hop_destroy }
    when_attach_set? { hop_attach }
    when_detach_set? { hop_detach }
    nap 6 * 60 * 60
  end

  label def attach
    decr_attach
    vm = Vm[frame.fetch("attach_vm_id")]
    fail "VM is not available" unless vm
    fail "Only Azure VMs can attach this volume right now" unless vm.azure_instance
    fail "VM must be in the same project" unless vm.project_id == block_volume.project_id
    fail "VM must be in the same location" unless vm.location_id == block_volume.location_id

    block_volume.update(state: "attaching", attached_vm_id: vm.id, updated_at: Time.now)
    lun = next_lun(vm)
    azure.update_virtual_machine_data_disks(
      resource_group: vm.azure_instance.resource_group,
      name: vm.azure_instance.vm_name,
      data_disks: current_data_disks(vm) + [{
        lun:,
        name: block_volume.provider_volume_name,
        createOption: "Attach",
        managedDisk: {id: block_volume.provider_volume_id},
      }]
    )
    block_volume.update(state: "attached", lun:, device_path: "/dev/disk/azure/data/by-lun/#{lun}", last_error: nil, updated_at: Time.now)
    hop_wait
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    block_volume.update(state: "failed", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Block volume attach failed", Util.exception_to_hash(ex).merge(block_volume_id: block_volume.id))
    nap 30 * 60
  end

  label def detach
    decr_detach
    vm = block_volume.attached_vm
    if vm&.azure_instance
      azure.update_virtual_machine_data_disks(
        resource_group: vm.azure_instance.resource_group,
        name: vm.azure_instance.vm_name,
        data_disks: current_data_disks(vm).reject { it["managedDisk"]&.[]("id") == block_volume.provider_volume_id || it["name"] == block_volume.provider_volume_name }
      )
    end
    block_volume.update(state: "available", attached_vm_id: nil, lun: nil, device_path: nil, last_error: nil, updated_at: Time.now)
    hop_wait
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    block_volume.update(state: "failed", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Block volume detach failed", Util.exception_to_hash(ex).merge(block_volume_id: block_volume.id))
    nap 30 * 60
  end

  label def destroy
    decr_destroy
    block_volume.update(state: "deleting", updated_at: Time.now)
    detach_provider_volume if block_volume.attached_vm_id
    azure.delete_disk(resource_group, block_volume.provider_volume_name) if resource_group && block_volume.provider_volume_name
    BillingRecord.finalize_active_for_resource(block_volume)
    block_volume.destroy
    pop "block volume destroyed"
  rescue Prog::Base::FlowControl
    raise
  rescue AzureAPIError => ex
    raise unless ex.not_found? || ex.retryable_delete?
    Clog.emit("Block volume delete waiting on Azure", {block_volume_id: block_volume.id, status: ex.status, body: ex.body})
    nap 30
  rescue => ex
    block_volume.update(state: "failed", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Block volume delete failed", Util.exception_to_hash(ex).merge(block_volume_id: block_volume.id))
    nap 30 * 60
  end

  private

  def create_provider_volume
    azure.create_resource_group(name: resource_group, region: azure_region, tags: {"LayerRail" => "true", "Project" => block_volume.project.ubid})
    result = azure.create_empty_disk(
      resource_group:,
      region: azure_region,
      name: block_volume.provider_volume_name,
      size_gib: block_volume.size_gib,
      tags: {
        "LayerRail" => "true",
        "Project" => block_volume.project.ubid,
        "BlockVolume" => block_volume.ubid,
      }
    )
    block_volume.update(provider_volume_id: result.fetch("id"), resource_group:, updated_at: Time.now)
  end

  def detach_provider_volume
    vm = block_volume.attached_vm
    return unless vm&.azure_instance

    azure.update_virtual_machine_data_disks(
      resource_group: vm.azure_instance.resource_group,
      name: vm.azure_instance.vm_name,
      data_disks: current_data_disks(vm).reject { it["managedDisk"]&.[]("id") == block_volume.provider_volume_id || it["name"] == block_volume.provider_volume_name }
    )
    block_volume.update(attached_vm_id: nil, lun: nil, device_path: nil, updated_at: Time.now)
  end

  def resource_group
    block_volume.resource_group || "lr-rg-vol-#{block_volume.ubid}".downcase
  end

  def azure_region
    block_volume.location.name.delete_prefix("azure-")
  end

  def current_data_disks(vm)
    azure.get_virtual_machine(vm.azure_instance.resource_group, vm.azure_instance.vm_name)
      .fetch("properties").fetch("storageProfile").fetch("dataDisks", [])
  end

  def next_lun(vm)
    used = current_data_disks(vm).map { it["lun"].to_i }
    (0..63).find { !used.include?(it) } || fail("No free Azure disk LUNs available")
  end

  def azure
    @azure ||= AzureClient.new
  end
end
