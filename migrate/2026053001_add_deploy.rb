# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:deploy_app) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :installation_id, :github_installation, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, on_delete: :set_null
      foreign_key :location_id, :location, type: :uuid, null: false
      column :name, String, null: false, collate: '"C"'
      column :repository, String, null: false, collate: '"C"'
      column :branch, String, null: false, default: "main", collate: '"C"'
      column :root_directory, String, null: false, default: "", collate: '"C"'
      column :install_command, String, null: false, default: "npm install"
      column :build_command, String
      column :start_command, String
      column :output_directory, String
      column :app_port, Integer, null: false, default: 3000
      column :status, String, null: false, default: "idle", collate: '"C"'
      column :hostname, String, collate: '"C"'
      column :vm_size, String, null: false, default: "nanode-1", collate: '"C"'
      column :framework, String, null: false, default: "node", collate: '"C"'
      column :failure_message, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index :project_id
      index :installation_id
      index :vm_id
    end

    create_table(:deploy_deployment) do
      column :id, :uuid, primary_key: true
      foreign_key :app_id, :deploy_app, type: :uuid, null: false
      column :status, String, null: false, default: "queued", collate: '"C"'
      column :trigger, String, null: false, default: "manual", collate: '"C"'
      column :commit_sha, String, collate: '"C"'
      column :commit_message, String
      column :log, String
      column :failure_message, String
      column :started_at, :timestamptz
      column :finished_at, :timestamptz
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index :app_id
      index [:app_id, :created_at]
    end

    create_table(:deploy_variable) do
      column :id, :uuid, primary_key: true
      foreign_key :app_id, :deploy_app, type: :uuid, null: false
      column :key, String, null: false, collate: '"C"'
      column :value, String, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:app_id, :key], unique: true
      index :app_id
    end

    run <<~SQL
      ALTER TABLE deploy_app
        ADD CONSTRAINT valid_deploy_app_status
        CHECK (status IN ('idle', 'provisioning', 'deploying', 'live', 'failed', 'deleting'));

      ALTER TABLE deploy_app
        ADD CONSTRAINT valid_deploy_app_port
        CHECK (app_port BETWEEN 1 AND 65535);

      ALTER TABLE deploy_deployment
        ADD CONSTRAINT valid_deploy_deployment_status
        CHECK (status IN ('queued', 'provisioning', 'building', 'live', 'failed', 'canceled'));
    SQL
  end

  down do
    drop_table(:deploy_variable)
    drop_table(:deploy_deployment)
    drop_table(:deploy_app)
  end
end
