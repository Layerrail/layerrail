# frozen_string_literal: true

require_relative "../model"

class BlockVolume < Sequel::Model
  many_to_one :project
  many_to_one :location
  many_to_one :attached_vm, class: :Vm, key: :attached_vm_id
  one_to_one :strand, key: :id
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, etc_type: true
  plugin SemaphoreMethods, :destroy, :attach, :detach

  def path
    "/volume/#{name}"
  end

  def display_location
    location.ui_name
  end

  def attachable?
    state == "available" && attached_vm_id.nil?
  end

  def detachable?
    state == "attached" && attached_vm_id
  end

  def ensure_billing_record!
    rate = BillingRate.from_resource_properties("BlockVolumeStorage", "standard", "global")
    fail "Block volume billing rate is not configured" unless rate
    return if active_billing_records_dataset.where(billing_rate_id: rate.fetch("id")).first

    BillingRecord.create(
      project_id: project_id,
      resource_id: id,
      resource_name: name,
      amount: size_gib,
      billing_rate_id: rate.fetch("id"),
      resource_tags: Sequel.pg_jsonb_wrap({"service" => "block-volume", "location" => location.name})
    )
  end

  def self.available_locations
    Location.where(provider: "azure", project_id: nil, visible: true).order(:ui_name).all
  end

  def self.generate_provider_name(project, name)
    "lr-vol-#{project.ubid}-#{name}".downcase.gsub(/[^a-z0-9-]/, "-")[0, 80].delete_suffix("-")
  end
end

# Table: block_volume
