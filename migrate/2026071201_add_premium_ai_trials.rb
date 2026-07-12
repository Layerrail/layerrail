# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:premium_ai_trial) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :started_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :ends_at, :timestamptz, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index :project_id, unique: true
      index :ends_at
    end
  end

  down do
    drop_table(:premium_ai_trial)
  end
end
