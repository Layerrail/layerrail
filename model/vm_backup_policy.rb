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
end

# Table: vm_backup_policy
