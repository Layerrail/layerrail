# frozen_string_literal: true

require_relative "../model"

class VmBackupSnapshot < Sequel::Model
  many_to_one :vm_backup_policy
  many_to_one :vm

  def available?
    state == "available"
  end
end

# Table: vm_backup_snapshot
