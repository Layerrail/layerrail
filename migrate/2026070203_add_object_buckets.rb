# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:object_bucket) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :minio_cluster_id, :minio_cluster, type: :uuid
      column :name, String, null: false, collate: '"C"'
      column :bucket_name, String, null: false, unique: true, collate: '"C"'
      column :access_key, String, null: false, collate: '"C"'
      column :secret_key, String, null: false, collate: '"C"'
      column :state, String, null: false, default: "creating", collate: '"C"'
      column :endpoint, String, collate: '"C"'
      column :last_error, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index [:project_id, :created_at]
      constraint(:valid_object_bucket_state, Sequel.lit("state IN ('creating', 'ready', 'failed', 'deleting')"))
    end
  end

  down do
    drop_table(:object_bucket)
  end
end
