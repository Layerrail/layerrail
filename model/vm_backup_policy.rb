# frozen_string_literal: true

require_relative "../model"

class VmBackupPolicy < Sequel::Model
  many_to_one :vm
  one_to_many :snapshots, class: :VmBackupSnapshot, order: Sequel.desc(:created_at)
  one_to_one :strand, key: :id

  plugin ResourceMethods, etc_type: true
  plugin SemaphoreMethods, :destroy

  def next_backup_due?
    enabled && next_backup_at <= Time.now
  end

  def schedule_next!(from: Time.now, error: nil)
    update(
      next_backup_at: from + schedule_hours * 60 * 60,
      last_error: error,
      updated_at: Time.now
    )
  end

  def billable_snapshot_gib
    snapshots_dataset.where(state: "available").sum(:size_gib).to_i
  end

  def sync_billing_record!
    rate = BillingRate.from_resource_properties("VmBackupStorage", "standard", "global")
    fail "VM backup billing rate is not configured" unless rate

    active_record = BillingRecord.where(resource_id: id, billing_rate_id: rate.fetch("id")).active.first
    amount = billable_snapshot_gib

    if amount.zero?
      active_record&.finalize
      return
    end

    return if active_record&.amount&.to_i == amount

    active_record&.finalize
    BillingRecord.create(
      project_id: vm.project_id,
      resource_id: id,
      resource_name: "#{vm.name} backups",
      amount: amount,
      billing_rate_id: rate.fetch("id"),
      resource_tags: Sequel.pg_jsonb_wrap({"service" => "vm-backup", "vm_id" => vm.id})
    )
  end
end

# Table: vm_backup_policy
