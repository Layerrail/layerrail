# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_backup_snapshot) do
      add_column :restore_vm_id, :uuid
      add_column :restored_at, :timestamptz
      add_index :restore_vm_id
    end
  end

  down do
    alter_table(:vm_backup_snapshot) do
      drop_index :restore_vm_id
      drop_column :restored_at
      drop_column :restore_vm_id
    end
  end
end
