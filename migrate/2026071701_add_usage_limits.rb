# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:usage_limit) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false, unique: true
      foreign_key :user_id, :accounts, type: :uuid, null: false
      column :limit, Integer, null: false
      column :period_start, Date, null: false, default: Sequel.lit("date_trunc('month', now())::date")
      column :last_notification_threshold, Integer, null: false, default: 0
      column :revision, Integer, null: false, default: 1
      column :suspended_at, :timestamptz
      column :suspended_revision, Integer
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      constraint(:usage_limit_positive, Sequel.lit("\"limit\" > 0"))
      constraint(:usage_limit_valid_notification_threshold, Sequel.lit("last_notification_threshold IN (0, 80, 90, 100)"))
      constraint(:usage_limit_positive_revision, Sequel.lit("revision > 0"))
      constraint(:usage_limit_valid_suspension, Sequel.lit("(suspended_at IS NULL) = (suspended_revision IS NULL)"))
    end

    create_table(:usage_limit_billing_record) do
      foreign_key :usage_limit_id, :usage_limit, type: :uuid, null: false, on_delete: :cascade
      column :billing_record_id, :uuid, null: false
      column :project_id, :uuid, null: false
      column :resource_id, :uuid, null: false
      column :resource_name, :text, null: false
      column :amount, :numeric, null: false
      column :billing_rate_id, :uuid, null: false
      column :resource_tags, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      column :snapshotted_at, :timestamptz, null: false

      primary_key [:usage_limit_id, :billing_record_id]
      index [:usage_limit_id, :resource_id]
    end

    create_table(:usage_limit_notification) do
      column :id, :uuid, primary_key: true
      foreign_key :usage_limit_id, :usage_limit, type: :uuid, null: false, on_delete: :cascade
      column :period_start, Date, null: false
      column :revision, Integer, null: false
      column :threshold, Integer, null: false
      column :current_cost, :numeric, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :delivered_at, :timestamptz

      index [:usage_limit_id, :period_start, :revision, :threshold], unique: true, name: :usage_limit_notification_event_uidx
      index [:usage_limit_id, :delivered_at]
      constraint(:usage_limit_notification_valid_threshold, Sequel.lit("threshold IN (80, 90, 100)"))
      constraint(:usage_limit_notification_positive_revision, Sequel.lit("revision > 0"))
      constraint(:usage_limit_notification_nonnegative_cost, Sequel.lit("current_cost >= 0"))
    end

    alter_table(:object_bucket) do
      drop_constraint(:valid_object_bucket_state)
      add_constraint(:valid_object_bucket_state, Sequel.lit("state IN ('creating', 'ready', 'suspended', 'failed', 'deleting')"))
    end

    alter_table(:edge_service) do
      drop_constraint(:valid_edge_state)
      add_constraint(:valid_edge_state, Sequel.lit("state IN ('creating', 'ready', 'suspended', 'failed', 'deleting')"))
    end

    alter_table(:game_vps) do
      drop_constraint(:valid_game_vps_status)
      add_constraint(:valid_game_vps_status, Sequel.lit("status IN ('pending_payment', 'creating', 'running', 'stopping', 'stopped', 'starting', 'failed', 'deleting', 'deleted')"))
    end
  end

  down do
    usage_limit_labels = %w[
      usage_limit_suspend usage_limit_suspended usage_limit_resume
      wait_usage_limit_suspended wait_usage_limit_resumed
    ]
    provider_power_labels = %w[stop wait_stopped stopped start_after_stop wait_started usage_limit_quarantine usage_limit_unquarantine]
    rollback_unsafe =
      from(:usage_limit).exclude(suspended_at: nil).any? ||
      from(:semaphore).where(name: %w[usage_limit_suspended usage_limit_resume]).any? ||
      from(:strand).where(label: usage_limit_labels).any? ||
      from(:strand).where(prog: %w[Vm::Aws::Nexus Vm::Gcp::Nexus], label: provider_power_labels).any? ||
      from(:object_bucket).where(state: "suspended").any? ||
      from(:edge_service).where(state: "suspended").any? ||
      from(:game_vps).where(status: %w[stopping stopped starting]).any?

    if rollback_unsafe
      raise Sequel::Error, "Cannot roll back usage limits while services are suspended or resuming; remove limits and wait for services to return to running first"
    end

    alter_table(:game_vps) do
      drop_constraint(:valid_game_vps_status)
      add_constraint(:valid_game_vps_status, Sequel.lit("status IN ('pending_payment', 'creating', 'running', 'failed', 'deleting', 'deleted')"))
    end

    alter_table(:edge_service) do
      drop_constraint(:valid_edge_state)
      add_constraint(:valid_edge_state, Sequel.lit("state IN ('creating', 'ready', 'failed', 'deleting')"))
    end

    alter_table(:object_bucket) do
      drop_constraint(:valid_object_bucket_state)
      add_constraint(:valid_object_bucket_state, Sequel.lit("state IN ('creating', 'ready', 'failed', 'deleting')"))
    end

    drop_table(:usage_limit_notification)
    drop_table(:usage_limit_billing_record)
    drop_table(:usage_limit)
  end
end