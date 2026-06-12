# frozen_string_literal: true

require "securerandom"

class Prog::GameVpsNexus < Prog::Base
  subject_is :game_vps

  def self.assemble(game_vps)
    Strand.create_with_id(game_vps, prog: "GameVpsNexus", label: "start")
  end

  def self.assemble_destroy(game_vps)
    if game_vps.strand
      game_vps.incr_destroy
    else
      Strand.create_with_id(game_vps, prog: "GameVpsNexus", label: "destroy")
    end
  end

  label def start
    fail "Game VPS provisioning is disabled" unless Config.game_vps_enabled

    game_vps.update(
      rdp_password: game_vps.rdp_password || secure_windows_password,
      txadmin_password: game_vps.txadmin_password || secure_windows_password,
      status: "creating",
      updated_at: Time.now,
    )

    hop_start_ionos if game_vps.provider == "ionos"
    hop_start_azure if game_vps.provider == "azure"

    fail "Game VPS provider #{game_vps.provider} is not supported"
  rescue => ex
    mark_failed(ex)
  end

  label def start_ionos
    result = client.create_datacenter(name: resource_name, location: game_vps.location)
    game_vps.update(datacenter_id: result.body.fetch("id"), request_status_url: result.status_url, updated_at: Time.now)
    hop_wait_datacenter
  rescue => ex
    mark_failed(ex)
  end

  label def wait_datacenter
    nap 5 unless client.request_done?(game_vps.request_status_url)

    result = client.create_lan(datacenter_id: game_vps.datacenter_id, name: "#{resource_name}-public")
    game_vps.update(lan_id: result.body.fetch("id"), request_status_url: result.status_url, updated_at: Time.now)
    hop_wait_lan
  rescue => ex
    mark_failed(ex)
  end

  label def wait_lan
    nap 5 unless client.request_done?(game_vps.request_status_url)

    result = client.create_server(
      datacenter_id: game_vps.datacenter_id,
      name: resource_name,
      cores: game_vps.cores,
      ram_gib: game_vps.ram_gib,
      cpu_family: Config.ionos_game_vps_cpu_family,
      image_alias: game_vps.image_alias,
      image_password: game_vps.rdp_password,
      disk_gib: game_vps.disk_gib,
      disk_type: Config.ionos_game_vps_disk_type,
      lan_id: game_vps.lan_id,
    )

    ids = extract_server_ids(result.body)
    game_vps.update(**ids, request_status_url: result.status_url, updated_at: Time.now)
    hop_wait_server
  rescue => ex
    mark_failed(ex)
  end

  label def wait_server
    nap 5 unless client.request_done?(game_vps.request_status_url)

    server = client.get_server(game_vps.datacenter_id, game_vps.server_id)
    primary_ip = client.primary_ip_for(server)
    vm_state = server.dig("properties", "vmState").to_s.upcase
    nap 10 if primary_ip.to_s.empty? || !["RUNNING", "AVAILABLE"].include?(vm_state)

    game_vps.update(
      status: "running",
      primary_ip:,
      access_notes: "RDP is available on TCP 3389. FiveM is open on TCP/UDP 30120. txAdmin is open on TCP 40120.",
      request_status_url: nil,
      updated_at: Time.now,
    )
    Clog.emit("IONOS Game VPS provisioned", {ionos_game_vps_provisioned: {game_vps_ubid: game_vps.ubid, datacenter_id: game_vps.datacenter_id, server_id: game_vps.server_id}})
    game_vps.prepaid? ? hop_wait : hop_create_billing_record
  rescue => ex
    mark_failed(ex)
  end

  label def start_azure
    register_deadline("wait_azure_server", 20 * 60)
    azure_client.create_resource_group(name: azure_resource_group, region: azure_region, tags: azure_tags)
    nsg = azure_client.create_game_network_security_group(resource_group: azure_resource_group, region: azure_region, name: azure_nsg_name, tags: azure_tags)
    vnet = azure_client.create_virtual_network(
      resource_group: azure_resource_group,
      region: azure_region,
      name: azure_vnet_name,
      subnet_name: azure_subnet_name,
      address_prefix: "10.60.0.0/24",
      nsg_id: nsg.fetch("id"),
      tags: azure_tags,
    )
    public_ip = azure_client.create_public_ip(resource_group: azure_resource_group, region: azure_region, name: azure_public_ip_name, tags: azure_tags)
    subnet_id = vnet.dig("properties", "subnets", 0, "id") || azure_client.subnet_resource_id(azure_resource_group, azure_vnet_name, azure_subnet_name)
    nic = azure_client.create_network_interface(
      resource_group: azure_resource_group,
      region: azure_region,
      name: azure_nic_name,
      subnet_id:,
      public_ip_id: public_ip.fetch("id"),
      private_ip: "10.60.0.4",
      tags: azure_tags,
    )
    azure_client.create_windows_virtual_machine(
      resource_group: azure_resource_group,
      region: azure_region,
      name: azure_vm_name,
      computer_name: azure_computer_name,
      vm_size: azure_vm_size,
      image: GameVps.azure_image_reference(game_vps.image_alias),
      username: game_vps.rdp_username,
      password: game_vps.rdp_password,
      nic_id: nic.fetch("id"),
      os_disk_name: azure_os_disk_name,
      os_disk_size_gib: game_vps.disk_gib,
      tags: azure_tags,
    )

    game_vps.update(
      datacenter_id: azure_resource_group,
      server_id: azure_vm_name,
      lan_id: azure_vnet_name,
      nic_id: azure_nic_name,
      volume_id: azure_public_ip_name,
      updated_at: Time.now,
    )
    hop_wait_azure_server
  rescue => ex
    mark_failed(ex)
  end

  label def wait_azure_server
    instance = azure_client.get_virtual_machine(azure_resource_group, azure_vm_name)
    statuses = Array(instance.dig("properties", "instanceView", "statuses")).map { it["code"] }
    provisioning_succeeded = statuses.include?("ProvisioningState/succeeded")
    power_running = statuses.include?("PowerState/running")

    if provisioning_succeeded && power_running
      primary_ip = azure_client.get_public_ip(azure_resource_group, azure_public_ip_name).dig("properties", "ipAddress")
      nap 5 if primary_ip.to_s.empty?

      game_vps.update(
        status: "running",
        primary_ip:,
        access_notes: "RDP is available on TCP 3389. FiveM is open on TCP/UDP 30120. txAdmin is open on TCP 40120. Minecraft is open on TCP 25565.",
        request_status_url: nil,
        updated_at: Time.now,
      )
      Clog.emit("Azure Game VPS provisioned", {azure_game_vps_provisioned: {game_vps_ubid: game_vps.ubid, resource_group: azure_resource_group, vm_name: azure_vm_name}})
      game_vps.prepaid? ? hop_wait : hop_create_billing_record
    end

    Clog.emit("Azure Game VPS is not running yet", {azure_game_vps_status: {game_vps_ubid: game_vps.ubid, vm_name: azure_vm_name, statuses:}})
    nap 10
  rescue AzureAPIError => ex
    Clog.emit("Azure Game VPS wait failed", {azure_game_vps_wait_failed: {game_vps_ubid: game_vps.ubid, status: ex.status, body: ex.body}})
    nap 15
  rescue => ex
    mark_failed(ex)
  end

  label def create_billing_record
    hop_wait unless game_vps.project.billable
    hop_wait if game_vps.prepaid?
    hop_wait unless game_vps.active_billing_records.empty?

    BillingRecord.create(
      project_id: game_vps.project_id,
      resource_id: game_vps.id,
      resource_name: game_vps.name,
      billing_rate_id: BillingRate.from_resource_properties("GameVpsPlan", game_vps.plan, "global").fetch("id"),
      amount: 1,
    )

    hop_wait
  end

  label def wait
    nap 6 * 60 * 60
  end

  def before_destroy
    register_deadline(nil, 10 * 60)
    game_vps.active_billing_records.each(&:finalize) unless game_vps.prepaid?
  end

  label def destroy
    decr_destroy
    if game_vps.status == "pending_payment" && game_vps.datacenter_id.nil? && game_vps.server_id.nil?
      game_vps.destroy
      pop "game vps pending checkout destroyed"
    end

    game_vps.update(status: "deleting", updated_at: Time.now) unless game_vps.status == "deleting"

    if game_vps.provider == "azure"
      azure_client.delete_resource_group(game_vps.datacenter_id || azure_resource_group)
      game_vps.destroy
      pop "game vps destroyed"
    end

    if game_vps.datacenter_id
      result = client.delete_datacenter(game_vps.datacenter_id)
      game_vps.update(request_status_url: result.status_url, updated_at: Time.now)
      hop_wait_destroy if result.status_url
    end

    game_vps.destroy
    pop "game vps destroyed"
  rescue IonosAPIError => ex
    if ex.status == 404
      game_vps.destroy
      pop "game vps destroyed"
    end
    mark_failed(ex)
  end

  label def wait_destroy
    nap 5 unless client.request_done?(game_vps.request_status_url)

    game_vps.destroy
    pop "game vps destroyed"
  rescue IonosAPIError => ex
    if ex.status == 404
      game_vps.destroy
      pop "game vps destroyed"
    end
    mark_failed(ex)
  end

  private

  def client
    @client ||= IonosClient.new
  end

  def azure_client
    @azure_client ||= AzureClient.new
  end

  def resource_name
    "lr-#{game_vps.ubid}"
  end

  def azure_region
    @azure_region ||= GameVps::LOCATIONS.fetch(game_vps.location).fetch(:azure_region)
  end

  def azure_plan
    @azure_plan ||= GameVps::PLANS.fetch(game_vps.plan)
  end

  def azure_vm_size
    azure_plan.fetch(:azure_size)
  end

  def azure_resource_group
    @azure_resource_group ||= azure_name("rg", 80)
  end

  def azure_vm_name
    @azure_vm_name ||= azure_name("game", 60)
  end

  def azure_computer_name
    @azure_computer_name ||= "lr#{game_vps.ubid[-12, 12]}".downcase.gsub(/[^a-z0-9]/, "")[0, 15]
  end

  def azure_vnet_name
    @azure_vnet_name ||= azure_name("vnet", 60)
  end

  def azure_subnet_name
    @azure_subnet_name ||= azure_name("subnet", 60)
  end

  def azure_nsg_name
    @azure_nsg_name ||= azure_name("nsg", 60)
  end

  def azure_nic_name
    @azure_nic_name ||= azure_name("nic", 60)
  end

  def azure_public_ip_name
    @azure_public_ip_name ||= azure_name("pip", 60)
  end

  def azure_os_disk_name
    @azure_os_disk_name ||= azure_name("osdisk", 60)
  end

  def azure_name(prefix, max_length)
    "lr-#{prefix}-#{game_vps.ubid}".downcase.gsub(/[^a-z0-9-]/, "-")[0, max_length].delete_suffix("-")
  end

  def azure_tags
    {
      "LayerRail" => "true",
      "Project" => game_vps.project.ubid,
      "GameVps" => game_vps.ubid,
    }
  end

  def secure_windows_password
    "#{SecureRandom.urlsafe_base64(26)}aA1!"
  end

  def extract_server_ids(body)
    server_id = body.fetch("id")
    volume_id = body.dig("entities", "volumes", "items", 0, "id")
    nic_id = body.dig("entities", "nics", "items", 0, "id")
    {server_id:, volume_id:, nic_id:}.compact
  end

  def mark_failed(ex)
    Clog.emit("Game VPS provisioning failed", {game_vps_failed: {game_vps_ubid: game_vps&.ubid, provider: game_vps&.provider, error_class: ex.class.name, error_message: ex.message}})
    game_vps.update(status: "failed", failure_message: ex.message.to_s.slice(0, 1000), updated_at: Time.now) if game_vps
    pop "game vps failed"
  end
end
