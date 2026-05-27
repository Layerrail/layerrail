# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('ionos') ON CONFLICT DO NOTHING;"

    create_table(:game_vps) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, String, null: false, collate: '"C"'
      column :provider, String, null: false, default: "ionos", collate: '"C"'
      column :status, String, null: false, default: "creating", collate: '"C"'
      column :plan, String, null: false, collate: '"C"'
      column :location, String, null: false, collate: '"C"'
      column :image_alias, String, null: false, collate: '"C"'
      column :datacenter_id, String, collate: '"C"'
      column :server_id, String, collate: '"C"'
      column :lan_id, String, collate: '"C"'
      column :nic_id, String, collate: '"C"'
      column :volume_id, String, collate: '"C"'
      column :request_status_url, String
      column :primary_ip, String, collate: '"C"'
      column :rdp_username, String, null: false, default: "Administrator", collate: '"C"'
      column :rdp_password, String
      column :txadmin_password, String
      column :failure_message, String
      column :access_notes, String
      column :cores, Integer, null: false
      column :ram_gib, Integer, null: false
      column :disk_gib, Integer, null: false
      column :monthly_price, :numeric, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index :project_id
    end

    run <<~SQL
      ALTER TABLE game_vps
        ADD CONSTRAINT valid_game_vps_status
        CHECK (status IN ('creating', 'running', 'failed', 'deleting', 'deleted'));
    SQL
  end

  down do
    drop_table(:game_vps)
    from(:provider).where(name: "ionos").delete
  end
end
