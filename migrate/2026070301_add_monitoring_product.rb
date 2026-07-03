# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:monitoring_notification_channel) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, String, null: false, collate: '"C"'
      column :kind, String, null: false, collate: '"C"'
      column :target, String, null: false, collate: '"C"'
      column :enabled, TrueClass, null: false, default: true
      column :last_tested_at, :timestamptz
      column :last_error, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      constraint(:valid_monitoring_notification_channel_kind, Sequel.lit("kind IN ('email', 'webhook')"))
    end

    create_table(:uptime_check) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, String, null: false, collate: '"C"'
      column :target_url, String, null: false, collate: '"C"'
      column :method, String, null: false, default: "GET", collate: '"C"'
      column :expected_status, Integer, null: false, default: 200
      column :interval_seconds, Integer, null: false, default: 60
      column :timeout_seconds, Integer, null: false, default: 10
      column :enabled, TrueClass, null: false, default: true
      column :state, String, null: false, default: "pending", collate: '"C"'
      column :last_checked_at, :timestamptz
      column :last_status_code, Integer
      column :last_latency_ms, Integer
      column :last_error, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index [:project_id, :state]
      constraint(:valid_uptime_check_method, Sequel.lit("method IN ('GET', 'HEAD')"))
      constraint(:valid_uptime_check_interval, Sequel.lit("interval_seconds BETWEEN 30 AND 86400"))
      constraint(:valid_uptime_check_timeout, Sequel.lit("timeout_seconds BETWEEN 1 AND 60"))
      constraint(:valid_uptime_check_state, Sequel.lit("state IN ('pending', 'up', 'down', 'paused')"))
    end

    create_table(:monitoring_alert) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :uptime_check_id, :uptime_check, type: :uuid, on_delete: :cascade
      foreign_key :notification_channel_id, :monitoring_notification_channel, type: :uuid, on_delete: :set_null
      column :name, String, null: false, collate: '"C"'
      column :resource_type, String, null: false, collate: '"C"'
      column :condition, String, null: false, collate: '"C"'
      column :threshold, BigDecimal, size: [20, 6]
      column :severity, String, null: false, default: "warning", collate: '"C"'
      column :enabled, TrueClass, null: false, default: true
      column :last_triggered_at, :timestamptz
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index [:project_id, :resource_type]
      constraint(:valid_monitoring_alert_resource_type, Sequel.lit("resource_type IN ('uptime', 'metrics', 'logs')"))
      constraint(:valid_monitoring_alert_condition, Sequel.lit("condition IN ('down', 'status_not_expected', 'latency_ms_gt', 'metric_gt', 'log_match')"))
      constraint(:valid_monitoring_alert_severity, Sequel.lit("severity IN ('info', 'warning', 'critical')"))
    end

    create_table(:monitoring_incident) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :monitoring_alert_id, :monitoring_alert, type: :uuid, on_delete: :set_null
      foreign_key :uptime_check_id, :uptime_check, type: :uuid, on_delete: :set_null
      column :title, String, null: false
      column :status, String, null: false, default: "open", collate: '"C"'
      column :severity, String, null: false, default: "warning", collate: '"C"'
      column :message, String
      column :opened_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :acknowledged_at, :timestamptz
      column :resolved_at, :timestamptz
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :status]
      index [:project_id, :opened_at]
      constraint(:valid_monitoring_incident_status, Sequel.lit("status IN ('open', 'acknowledged', 'resolved')"))
      constraint(:valid_monitoring_incident_severity, Sequel.lit("severity IN ('info', 'warning', 'critical')"))
    end
  end

  down do
    drop_table(:monitoring_incident)
    drop_table(:monitoring_alert)
    drop_table(:uptime_check)
    drop_table(:monitoring_notification_channel)
  end
end
