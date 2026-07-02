# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:vm_backup_policy) do
      column :id, :uuid, primary_key: true
      foreign_key :vm_id, :vm, type: :uuid, null: false, unique: true, on_delete: :cascade
      column :enabled, TrueClass, null: false, default: true
      column :schedule_hours, Integer, null: false, default: 24
      column :retention_days, Integer, null: false, default: 7
      column :last_backup_at, :timestamptz
      column :next_backup_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :last_error, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      constraint(:valid_vm_backup_schedule_hours, Sequel.lit("schedule_hours IN (6, 12, 24, 168)"))
      constraint(:valid_vm_backup_retention_days, Sequel.lit("retention_days BETWEEN 1 AND 90"))
    end

    create_table(:vm_backup_snapshot) do
      primary_key :id
      foreign_key :vm_backup_policy_id, :vm_backup_policy, type: :uuid, null: false, on_delete: :cascade
      foreign_key :vm_id, :vm, type: :uuid, null: false, on_delete: :cascade
      column :provider, String, null: false, collate: '"C"'
      column :state, String, null: false, default: "creating", collate: '"C"'
      column :reason, String, null: false, default: "scheduled", collate: '"C"'
      column :snapshot_refs, :jsonb, null: false, default: "[]"
      column :size_gib, Integer, null: false, default: 0
      column :error_message, String
      column :expires_at, :timestamptz, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :completed_at, :timestamptz

      index [:vm_id, :created_at]
      index [:state, :expires_at]
      constraint(:valid_vm_backup_snapshot_state, Sequel.lit("state IN ('creating', 'available', 'failed', 'deleting')"))
      constraint(:valid_vm_backup_snapshot_reason, Sequel.lit("reason IN ('manual', 'scheduled')"))
    end
  end

  down do
    drop_table(:vm_backup_snapshot)
    drop_table(:vm_backup_policy)
  end
end
