# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('azure') ON CONFLICT DO NOTHING;"

    create_table(:azure_instance) do
      foreign_key :id, :vm, type: :uuid, primary_key: true, on_delete: :cascade
      column :resource_group, String, null: false, collate: '"C"'
      column :region, String, null: false, collate: '"C"'
      column :vm_name, String, null: false, unique: true, collate: '"C"'
      column :vm_size, String, null: false, collate: '"C"'
      column :image, :jsonb, null: false, default: "{}"
      column :vnet_name, String, null: false, collate: '"C"'
      column :subnet_name, String, null: false, collate: '"C"'
      column :nsg_name, String, null: false, collate: '"C"'
      column :nic_name, String, null: false, collate: '"C"'
      column :public_ip_name, String, null: false, collate: '"C"'
      column :os_disk_name, String, null: false, collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    create_table(:azure_storage_volume) do
      foreign_key :id, :vm_storage_volume, type: :uuid, primary_key: true, on_delete: :cascade
      column :disk_name, String, null: false, unique: true, collate: '"C"'
      column :lun, Integer, null: false
      column :device_path, String, null: false, collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        ('azure', 'azure-eastus', 'azure-eastus', 'East US', true, '14c07e26-4e48-41c3-a8bb-831d70f05c5d'),
        ('azure', 'azure-westus3', 'azure-westus3', 'West US 3', true, '85e585f9-b13a-4b9e-b0fb-06bdfcc93fd9'),
        ('azure', 'azure-westeurope', 'azure-westeurope', 'West Europe', true, '4f9d5ec4-ec46-496e-a50b-8b846472f035'),
        ('azure', 'azure-northeurope', 'azure-northeurope', 'North Europe', true, 'a623ad21-f816-4866-b6a3-5d9fe4f02c5a')
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    from(:location).where(provider: "azure").delete
    drop_table(:azure_storage_volume)
    drop_table(:azure_instance)
    from(:provider).where(name: "azure").delete
  end
end
