# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:deploy_app) do
      add_column :environment, String, null: false, default: "production", collate: '"C"'
      add_foreign_key :production_app_id, :deploy_app, type: :uuid, on_delete: :set_null
      add_column :preview_key, String, collate: '"C"'
      add_column :auto_deploy, :boolean, null: false, default: true
      add_column :build_cache_enabled, :boolean, null: false, default: true
      add_index :production_app_id
      add_index [:project_id, :environment]
      add_index [:project_id, :preview_key]
    end

    alter_table(:deploy_deployment) do
      add_column :image_ref, String, collate: '"C"'
      add_column :source_ref, String, collate: '"C"'
      add_index :image_ref
    end

    run <<~SQL
      ALTER TABLE deploy_app
        ADD CONSTRAINT valid_deploy_app_environment
        CHECK (environment IN ('production', 'preview', 'development'));
    SQL
  end

  down do
    run "ALTER TABLE deploy_app DROP CONSTRAINT IF EXISTS valid_deploy_app_environment;"

    alter_table(:deploy_deployment) do
      drop_index :image_ref
      drop_column :source_ref
      drop_column :image_ref
    end

    alter_table(:deploy_app) do
      drop_index [:project_id, :preview_key]
      drop_index [:project_id, :environment]
      drop_index :production_app_id
      drop_column :build_cache_enabled
      drop_column :auto_deploy
      drop_column :preview_key
      drop_column :production_app_id
      drop_column :environment
    end
  end
end
