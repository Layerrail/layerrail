# frozen_string_literal: true

require "base64"
require "securerandom"

class Prog::Vm::Linode::Nexus < Prog::Base
  subject_is :vm

  def before_destroy
    register_deadline(nil, 5 * 60)
    vm.active_billing_records.each(&:finalize)
  end

  label def start
    register_deadline("wait", 10 * 60)
    nap 2 unless nic.private_subnet.strand.label == "wait"
    nap 1 unless nic.strand.label == "wait"

    hop_wait_instance_created if vm.linode_instance

    instance = client.create_linode(linode_payload)
    LinodeInstance.create_with_id(
      vm,
      linode_id: instance.fetch("id"),
      region: linode_region,
      linode_type: linode_type,
      image: linode_image,
      label: vm.name,
    )
    hop_wait_instance_created
  end

  label def wait_instance_created
    instance = client.get_linode(vm.linode_instance.linode_id)

    case instance["status"]
    when "running"
      nap 5 unless linode_data_volumes_ready?

      public_ipv4 = public_ipv4_for(instance)
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4) if public_ipv4 && !vm.assigned_vm_address
      vm.sshable&.update(host: public_ipv4) if public_ipv4

      vm.update(
        cores: [vm.vcpus / 2, 1].max,
        allocated_at: Time.now,
        display_state: "running",
        provisioned_at: Time.now,
        ephemeral_net6: public_ipv6_for(instance),
      )
      Clog.emit("Linode VM provisioned", {linode_vm_provisioned: {vm_ubid: vm.ubid, linode_id: vm.linode_instance.linode_id}})
      hop_create_billing_record
    when "provisioning", "booting", "rebooting", "migrating"
      nap 5
    else
      Clog.emit("Linode VM is not running yet", {linode_vm_status: {vm_ubid: vm.ubid, linode_id: vm.linode_instance.linode_id, status: instance["status"]}})
      nap 10
    end
  end

  label def create_billing_record
    project = vm.project
    hop_wait unless project.billable
    hop_wait unless vm.active_billing_records.empty?

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus,
    )

    if linode_plan.gpu_count.positive?
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("Gpu", linode_plan.gpu_device, vm.location.name)["id"],
        amount: linode_plan.gpu_count,
      )
    end

    vm.vm_storage_volumes.each do |vol|
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: "Disk ##{vol.disk_index} of #{vm.name}",
        billing_rate_id: BillingRate.from_resource_properties("VmStorage", vm.family, vm.location.name)["id"],
        amount: vol.size_gib,
      )
    end

    hop_wait
  end

  label def wait
    when_stop_set? do
      hop_stop
    end

    when_start_set? do
      hop_start_after_stop
    end

    when_restart_set? do
      hop_restart
    end

    when_update_firewall_rules_set? do
      hop_update_firewall_rules
    end

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
    client.shutdown_linode(vm.linode_instance.linode_id)
    hop_wait_stopped
  end

  label def wait_stopped
    instance = client.get_linode(vm.linode_instance.linode_id)
    nap 5 unless instance["status"] == "offline"
    hop_stopped
  end

  label def stopped
    when_start_set? do
      hop_start_after_stop
    end

    when_restart_set? do
      hop_start_after_stop
    end

    nap 6 * 60 * 60
  end

  label def start_after_stop
    decr_start if vm.start_set?
    decr_restart if vm.restart_set?
    client.boot_linode(vm.linode_instance.linode_id)
    vm.update(display_state: "creating")
    hop_wait_instance_created
  end

  label def restart
    decr_restart
    client.reboot_linode(vm.linode_instance.linode_id)
    vm.update(display_state: "creating")
    hop_wait_instance_created
  end

  label def destroy
    decr_destroy
    vm.update(display_state: "deleting")
    delete_linode_data_volumes
    client.delete_linode(vm.linode_instance.linode_id) if vm.linode_instance
    vm.linode_instance&.destroy
    final_clean_up
    pop "vm destroyed"
  end

  private

  def client
    @client ||= LinodeClient.new
  end

  def nic
    @nic ||= vm.nic
  end

  def linode_region
    @linode_region ||= vm.location.name.delete_prefix("linode-")
  end

  def linode_type
    @linode_type ||= linode_plan.id
  end

  def linode_plan
    @linode_plan ||= Option.linode_plan(vm.family, vm.vcpus, gpu_count: frame["gpu_count"] || 0, gpu_device: frame["gpu_device"])
  end

  def linode_image
    @linode_image ||= Option.linode_image_name(vm.boot_image)
  end

  def linode_payload
    {
      "label" => vm.name,
      "region" => linode_region,
      "type" => linode_type,
      "image" => linode_image,
      "root_pass" => SecureRandom.urlsafe_base64(32) + "aA1!",
      "authorized_keys" => [vm.public_key],
      "booted" => true,
      "private_ip" => true,
      "interface_generation" => "legacy_config",
      "firewall_id" => nic.private_subnet.private_subnet_linode_resource&.firewall_id,
      "metadata" => {
        "user_data" => Base64.strict_encode64(cloud_init),
      },
      "tags" => ["LayerRail", vm.project.ubid],
    }.compact
  end

  def linode_data_volumes_ready?
    data_volumes = vm.vm_storage_volumes.reject(&:boot)
    return true if data_volumes.empty?

    data_volumes.each do |volume|
      next if volume.linode_storage_volume

      created = client.create_volume(
        label: volume.linode_volume_label,
        region: linode_region,
        size: volume.size_gib,
        linode_id: vm.linode_instance.linode_id,
      )

      LinodeStorageVolume.create_with_id(
        volume,
        volume_id: created.fetch("id"),
        label: created.fetch("label"),
        filesystem_path: created["filesystem_path"] || "/dev/disk/by-id/scsi-0Linode_Volume_#{created.fetch("label")}",
      )
    end

    data_volumes.all? do |volume|
      linode_volume = volume.reload.linode_storage_volume
      next false unless linode_volume

      remote = client.get_volume(linode_volume.volume_id)
      remote["status"] == "active" && remote["linode_id"] == vm.linode_instance.linode_id
    end
  rescue LinodeAPIError => ex
    Clog.emit("Linode block volume is not ready", {linode_volume_wait: {vm_ubid: vm.ubid, status: ex.status, body: ex.body}})
    false
  end

  def delete_linode_data_volumes
    vm.vm_storage_volumes.reject(&:boot).each do |volume|
      next unless (linode_volume = volume.linode_storage_volume)

      client.detach_volume(linode_volume.volume_id)
      client.delete_volume(linode_volume.volume_id)
      linode_volume.destroy
    rescue LinodeAPIError => ex
      raise unless ex.status == 404
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

  def public_ipv4_for(instance)
    Array(instance["ipv4"]).find { public_ipv4?(it) }
  end

  def public_ipv4?(ip)
    return false unless ip

    octets = ip.split(".").map(&:to_i)
    return false unless octets.length == 4

    return false if octets[0] == 10
    return false if octets[0] == 127
    return false if octets[0] == 169 && octets[1] == 254
    return false if octets[0] == 172 && octets[1].between?(16, 31)
    return false if octets[0] == 192 && octets[1] == 168

    true
  end

  def public_ipv6_for(instance)
    value = instance["ipv6"]
    value&.split("/")&.first
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
