# frozen_string_literal: true

require "base64"

class Prog::Vm::Azure::Nexus < Prog::Base
  subject_is :vm

  def before_destroy
    register_deadline(nil, 30 * 60)
    vm.active_billing_records.each(&:finalize)
  end

  label def start
    register_deadline("wait", 15 * 60)
    nap 2 unless nic.private_subnet.strand.label == "wait"
    nap 1 unless nic.strand.label == "wait"

    hop_wait_instance_created if vm.azure_instance

    create_azure_storage_volume_records
    client.create_resource_group(name: resource_group, region: azure_region, tags:)
    nsg = client.create_network_security_group(resource_group:, region: azure_region, name: nsg_name, tags:)
    vnet = client.create_virtual_network(
      resource_group:,
      region: azure_region,
      name: vnet_name,
      subnet_name:,
      address_prefix: nic.private_subnet.net4.to_s,
      nsg_id: nsg.fetch("id"),
      tags:,
    )
    public_ip = client.create_public_ip(resource_group:, region: azure_region, name: public_ip_name, tags:)
    subnet_id = vnet.dig("properties", "subnets", 0, "id") || client.subnet_resource_id(resource_group, vnet_name, subnet_name)
    nic_resource = client.create_network_interface(
      resource_group:,
      region: azure_region,
      name: nic_name,
      subnet_id:,
      public_ip_id: public_ip.fetch("id"),
      private_ip: nic.private_ipv4_address,
      enable_ip_forwarding: kubernetes_vm?,
      tags:,
    )
    create_virtual_machine(nic_resource.fetch("id"))
    AzureInstance.create_with_id(
      vm,
      resource_group:,
      region: azure_region,
      vm_name:,
      vm_size: azure_vm_size,
      image: azure_image,
      vnet_name:,
      subnet_name:,
      nsg_name:,
      nic_name:,
      public_ip_name:,
      os_disk_name:,
    )
    hop_wait_instance_created
  rescue AzureAPIError => ex
    if retryable_azure_create_error?(ex)
      Clog.emit("Azure VM create is waiting on Azure resource convergence", {
        azure_vm_create_waiting: {
          vm_ubid: vm.ubid,
          location: azure_region,
          vm_size: azure_vm_size,
          image: azure_image,
          status: ex.status,
          body: ex.body,
        },
      })
      nap 30
    end

    failure = {
      vm_ubid: vm.ubid,
      location: azure_region,
      vm_size: azure_vm_size,
      image: azure_image,
      status: ex.status,
      body: ex.body,
    }
    Clog.emit("Azure VM create failed", {azure_vm_create_failed: failure})
    vm.update(display_state: "failed")
    Prog::PageNexus.assemble(
      "#{vm.ubid} Azure VM create failed",
      ["AzureCreateFailed", vm.id],
      vm.ubid,
      extra_data: failure,
    )
    nap 6 * 60 * 60
  end

  label def wait_instance_created
    instance = client.get_virtual_machine(resource_group, vm_name)
    statuses = Array(instance.dig("properties", "instanceView", "statuses")).map { it["code"] }
    provisioning_succeeded = statuses.include?("ProvisioningState/succeeded")
    power_running = statuses.include?("PowerState/running")

    if provisioning_succeeded && power_running
      public_ipv4 = client.get_public_ip(resource_group, public_ip_name).dig("properties", "ipAddress")
      nap 5 unless public_ipv4

      AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4) unless vm.assigned_vm_address
      vm.sshable&.update(host: public_ipv4)
      vm.update(
        cores: [vm.vcpus / 2, 1].max,
        allocated_at: Time.now,
        display_state: "running",
        provisioned_at: Time.now,
        ephemeral_net6: nic.private_ipv6,
      )
      Clog.emit("Azure VM provisioned", {azure_vm_provisioned: {vm_ubid: vm.ubid, vm_name:, resource_group:}})
      hop_create_billing_record
    end

    Clog.emit("Azure VM is not running yet", {azure_vm_status: {vm_ubid: vm.ubid, vm_name:, statuses:}})
    nap 10
  rescue AzureAPIError => ex
    Clog.emit("Azure VM wait failed", {azure_vm_wait_failed: {vm_ubid: vm.ubid, status: ex.status, body: ex.body}})
    nap 15
  end

  label def create_billing_record
    project = vm.project
    hop_wait unless project.billable
    hop_wait unless vm.active_billing_records.empty?

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", azure_plan.billing_family, vm.location.name)["id"],
      amount: (vm.family == "nanode") ? 1 : vm.vcpus,
    )

    vm.vm_storage_volumes.each do |vol|
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: "Disk ##{vol.disk_index} of #{vm.name}",
        billing_rate_id: BillingRate.from_resource_properties("VmStorage", vm.family, vm.location.name)["id"],
        amount: vol.size_gib,
      )
    end

    if vm.ip4_enabled && vm.assigned_vm_address
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location.name)["id"],
        amount: 1,
      )
    end

    hop_wait
  end

  label def wait
    when_usage_limit_suspended_set? { hop_stop }
    when_stop_set? { hop_stop }
    when_start_set? { hop_start_after_stop }
    when_restart_set? { hop_restart }
    when_update_firewall_rules_set? { hop_update_firewall_rules }
    nap 6 * 60 * 60
  end

  label def update_firewall_rules
    if retval&.dig("msg") == "firewall rule is added"
      hop_wait
    end

    decr_update_firewall_rules
    push vm.update_firewall_rules_prog, {}, :update_firewall_rules
  end

  label def stop
    decr_stop
    client.shutdown_virtual_machine(resource_group, vm_name)
    vm.update(display_state: "stopping")
    hop_wait_stopped
  end

  label def wait_stopped
    statuses = Array(client.get_virtual_machine(resource_group, vm_name).dig("properties", "instanceView", "statuses")).map { it["code"] }
    nap 5 unless statuses.include?("PowerState/deallocated") || statuses.include?("PowerState/stopped")
    hop_stopped
  rescue AzureAPIError
    nap 10
  end

  label def stopped
    unless usage_limit_suspended_set?
      when_start_set? { hop_start_after_stop }
      when_restart_set? { hop_start_after_stop }
    end
    nap 6 * 60 * 60
  end

  label def start_after_stop
    decr_start if vm.start_set?
    decr_restart if vm.restart_set?
    client.power_on_virtual_machine(resource_group, vm_name)
    vm.update(display_state: "creating")
    hop_wait_instance_created
  end

  label def restart
    decr_restart
    client.restart_virtual_machine(resource_group, vm_name)
    vm.update(display_state: "creating")
    hop_wait_instance_created
  end

  label def destroy
    decr_destroy
    vm.update(display_state: "deleting")
    delete_azure_resources
    final_clean_up
    pop "vm destroyed"
  end

  private

  def client
    @client ||= AzureClient.new
  end

  def nic
    @nic ||= vm.nic
  end

  def azure_region
    @azure_region ||= vm.location.name.delete_prefix("azure-")
  end

  def azure_plan
    @azure_plan ||= Option.azure_plan(vm.family, vm.vcpus, memory_gib: (vm.family == "nanode") ? vm.memory_gib : nil, location: vm.location)
  end

  def azure_vm_size
    @azure_vm_size ||= azure_plan.id
  end

  def azure_image
    @azure_image ||= Option.azure_image_reference(vm.boot_image)
  end

  def resource_group
    @resource_group ||= azure_subnet_name("rg", 80)
  end

  def vm_name
    @vm_name ||= azure_name("vm", 60)
  end

  def vnet_name
    @vnet_name ||= azure_subnet_name("vnet", 60)
  end

  def subnet_name
    @subnet_name ||= azure_subnet_name("subnet", 60)
  end

  def nsg_name
    @nsg_name ||= azure_subnet_name("nsg", 60)
  end

  def nic_name
    @nic_name ||= azure_name("nic", 60)
  end

  def public_ip_name
    @public_ip_name ||= azure_name("pip", 60)
  end

  def os_disk_name
    @os_disk_name ||= restored_disks? ? restored_os_disk.fetch("name") : azure_name("osdisk", 60)
  end

  def azure_name(prefix, max_length)
    "lr-#{prefix}-#{vm.ubid}".downcase.gsub(/[^a-z0-9-]/, "-")[0, max_length].delete_suffix("-")
  end

  def azure_subnet_name(prefix, max_length)
    "lr-#{prefix}-#{nic.private_subnet.ubid}".downcase.gsub(/[^a-z0-9-]/, "-")[0, max_length].delete_suffix("-")
  end

  def tags
    {
      "LayerRail" => "true",
      "Project" => vm.project.ubid,
      "VM" => vm.ubid,
    }
  end

  def kubernetes_vm?
    vm.boot_image.to_s.start_with?("kubernetes-")
  end

  def boot_volume
    @boot_volume ||= vm.vm_storage_volumes.find(&:boot)
  end

  def data_volumes
    @data_volumes ||= vm.vm_storage_volumes.reject(&:boot).sort_by(&:disk_index)
  end

  def create_azure_storage_volume_records
    data_volumes.each_with_index do |volume, index|
      next if AzureStorageVolume[volume.id]
      restored_disk = restored_disks? && frame.fetch("restored_disks").find { it["role"] == "data" && it["lun"].to_i == index }

      az = AzureStorageVolume.create_with_id(
        volume,
        disk_name: restored_disk&.fetch("name") || azure_name("disk-#{volume.disk_index}", 60),
        lun: index,
        device_path: "/dev/disk/azure/data/by-lun/#{index}",
      )
      volume.associations[:azure_storage_volume] = az
    end
  end

  def data_disks_payload
    {
      boot_size_gib: boot_volume.size_gib,
      volumes: data_volumes.map do |volume|
        az = AzureStorageVolume[volume.id] || fail("Azure storage volume record is missing for #{volume.ubid}")
        {
          lun: az.lun,
          name: az.disk_name,
          createOption: "Empty",
          diskSizeGB: volume.size_gib,
          managedDisk: {storageAccountType: "Premium_LRS"},
        }
      end,
    }
  end

  def create_virtual_machine(nic_id)
    if restored_disks?
      client.create_virtual_machine_from_disks(
        resource_group:,
        region: azure_region,
        name: vm_name,
        vm_size: azure_vm_size,
        username: vm.unix_user,
        ssh_key: vm.public_key,
        custom_data: Base64.strict_encode64(cloud_init),
        nic_id:,
        os_disk_name:,
        os_disk_id: restored_os_disk.fetch("id"),
        data_disks: restored_data_disks_payload,
        tags:,
      )
    else
      client.create_virtual_machine(
        resource_group:,
        region: azure_region,
        name: vm_name,
        vm_size: azure_vm_size,
        image: azure_image,
        username: vm.unix_user,
        ssh_key: vm.public_key,
        custom_data: Base64.strict_encode64(cloud_init),
        nic_id:,
        os_disk_name:,
        data_disks: data_disks_payload,
        tags:,
      )
    end
  end

  def restored_disks?
    frame["restored_disks"] && !frame["restored_disks"].empty?
  end

  def restored_os_disk
    @restored_os_disk ||= frame.fetch("restored_disks").find { it["role"] == "os" } || fail("Restored OS disk is missing")
  end

  def restored_data_disks_payload
    frame.fetch("restored_disks").select { it["role"] == "data" }.map do |disk|
      {
        lun: disk.fetch("lun"),
        name: disk.fetch("name"),
        createOption: "Attach",
        managedDisk: {id: disk.fetch("id")},
      }
    end
  end

  def cloud_init
    public_keys = ([vm.public_key] + (vm.project.get_ff_vm_public_ssh_keys || [])).map { yaml_quote(it) }
    <<~CLOUD_INIT
      #cloud-config
      users:
        - default
        - name: #{vm.unix_user}
          groups: sudo
          shell: /bin/bash
          sudo: ['ALL=(ALL) NOPASSWD:ALL']
          ssh_authorized_keys:
      #{public_keys.map { "      - #{it}" }.join("\n")}
      disable_root: true
      package_update: true
    CLOUD_INIT
  end

  def yaml_quote(value)
    "'#{value.gsub("'", "''")}'"
  end

  def delete_azure_resources
    if (instance = vm.azure_instance)
      delete_azure_resource(:virtual_machine, instance.vm_name) { client.delete_virtual_machine(instance.resource_group, instance.vm_name) }
      data_volumes.each do |volume|
        az = volume.azure_storage_volume
        delete_azure_resource(:disk, az.disk_name) { client.delete_disk(instance.resource_group, az.disk_name) } if az
      end
      delete_azure_resource(:disk, instance.os_disk_name) { client.delete_disk(instance.resource_group, instance.os_disk_name) }
      delete_azure_resource(:network_interface, instance.nic_name) { client.delete_network_interface(instance.resource_group, instance.nic_name) }
      delete_azure_resource(:public_ip, instance.public_ip_name) { client.delete_public_ip(instance.resource_group, instance.public_ip_name) }
      vm.azure_instance&.destroy
    end
    vm.vm_storage_volumes.each { it.azure_storage_volume&.destroy }
  end

  def delete_azure_resource(resource_type, name)
    yield
  rescue AzureAPIError => ex
    return if ex.not_found?
    raise unless ex.retryable_delete?

    Clog.emit("Azure VM delete is waiting on resource cleanup", {
      azure_vm_delete_waiting: {
        vm_ubid: vm.ubid,
        resource_type:,
        name:,
        status: ex.status,
        body: ex.body,
      },
    })
    nap 30
  end

  def retryable_azure_create_error?(ex)
    ex.retryable_create?
  end

  def final_clean_up
    vm.nics.each do |nic|
      nic.update(vm_id: nil)
      nic.incr_destroy
    end
    vm.assigned_vm_address&.destroy
    vm.destroy
  end
end
