# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:edge_service) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, String, null: false, collate: '"C"'
      column :hostname, String, null: false, unique: true, collate: '"C"'
      column :origin_url, String, null: false
      column :cache_mode, String, null: false, default: "standard", collate: '"C"'
      column :tls_mode, String, null: false, default: "full", collate: '"C"'
      column :state, String, null: false, default: "creating", collate: '"C"'
      column :last_error, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index [:project_id, :created_at]
      constraint(:valid_edge_cache_mode, Sequel.lit("cache_mode IN ('standard', 'aggressive', 'bypass')"))
      constraint(:valid_edge_tls_mode, Sequel.lit("tls_mode IN ('full', 'strict')"))
      constraint(:valid_edge_state, Sequel.lit("state IN ('creating', 'ready', 'failed', 'deleting')"))
    end
  end

  down do
    drop_table(:edge_service)
  end
end
