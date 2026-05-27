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
    fail "IONOS is the only supported Game VPS provider" unless Config.game_vps_provider == "ionos"

    game_vps.update(
      rdp_password: game_vps.rdp_password || secure_windows_password,
      txadmin_password: game_vps.txadmin_password || secure_windows_password,
      status: "creating",
      updated_at: Time.now,
    )

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
    hop_create_billing_record
  rescue => ex
    mark_failed(ex)
  end

  label def create_billing_record
    hop_wait unless game_vps.project.billable
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
    game_vps.active_billing_records.each(&:finalize)
  end

  label def destroy
    decr_destroy
    game_vps.update(status: "deleting", updated_at: Time.now) unless game_vps.status == "deleting"

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

  def resource_name
    "lr-#{game_vps.ubid}"
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
    Clog.emit("IONOS Game VPS provisioning failed", {ionos_game_vps_failed: {game_vps_ubid: game_vps&.ubid, error_class: ex.class.name, error_message: ex.message}})
    game_vps.update(status: "failed", failure_message: ex.message.to_s.slice(0, 1000), updated_at: Time.now) if game_vps
    pop "game vps failed"
  end
end
