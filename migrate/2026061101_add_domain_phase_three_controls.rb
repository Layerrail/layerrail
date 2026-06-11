# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:domain_registration) do
      add_foreign_key :deploy_app_id, :deploy_app, type: :uuid, on_delete: :set_null
      add_column :deploy_attached_at, :timestamptz
      add_column :team_policy, :jsonb, null: false, default: "{}"
      add_index :deploy_app_id
    end

    create_table(:domain_bundle) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :domain_registration_id, :domain_registration, type: :uuid, on_delete: :set_null
      foreign_key :deploy_app_id, :deploy_app, type: :uuid, on_delete: :set_null

      column :name, String, null: false, collate: '"C"'
      column :slug, String, null: false, collate: '"C"'
      column :bundle_type, String, null: false, default: "startup", collate: '"C"'
      column :status, String, null: false, default: "draft", collate: '"C"'
      column :description, String
      column :settings, :jsonb, null: false, default: "{}"
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:project_id, :slug], unique: true
      index [:project_id, :status]
      index :domain_registration_id
      index :deploy_app_id
    end

    run <<~SQL
      ALTER TABLE domain_bundle
        ADD CONSTRAINT valid_domain_bundle_type
        CHECK (bundle_type IN ('startup', 'saas', 'game_server', 'ai_app', 'custom'));

      ALTER TABLE domain_bundle
        ADD CONSTRAINT valid_domain_bundle_status
        CHECK (status IN ('draft', 'active', 'archived'));

      ALTER TABLE domain_bundle
        ADD CONSTRAINT valid_domain_bundle_slug
        CHECK (slug ~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    SQL
  end

  down do
    drop_table(:domain_bundle)

    alter_table(:domain_registration) do
      drop_index :deploy_app_id
      drop_column :team_policy
      drop_column :deploy_attached_at
      drop_column :deploy_app_id
    end
  end
end
