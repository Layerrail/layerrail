# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:linode_storage_volume) do
      foreign_key :id, :vm_storage_volume, type: :uuid, primary_key: true, on_delete: :cascade
      column :volume_id, Integer, null: false, unique: true
      column :label, String, null: false, unique: true, collate: '"C"'
      column :filesystem_path, String, null: false, collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end

  down do
    drop_table(:linode_storage_volume)
  end
end
