# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:block_volume) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :attached_vm_id, :vm, type: :uuid, null: true, on_delete: :set_null
      column :name, String, null: false, collate: '"C"'
      column :provider, String, null: false, default: "azure", collate: '"C"'
      column :provider_volume_id, String, collate: '"C"'
      column :provider_volume_name, String, null: false, unique: true, collate: '"C"'
      column :resource_group, String, collate: '"C"'
      column :size_gib, Integer, null: false
      column :device_path, String, collate: '"C"'
      column :lun, Integer
      column :state, String, null: false, default: "creating", collate: '"C"'
      column :last_error, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index [:project_id, :created_at]
      constraint(:valid_block_volume_size, Sequel.lit("size_gib BETWEEN 10 AND 4096"))
      constraint(:valid_block_volume_state, Sequel.lit("state IN ('creating', 'available', 'attaching', 'attached', 'detaching', 'deleting', 'failed')"))
    end
  end

  down do
    drop_table(:block_volume)
  end
end
