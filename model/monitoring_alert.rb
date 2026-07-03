# frozen_string_literal: true

require_relative "../model"

class MonitoringAlert < Sequel::Model
  many_to_one :project
  many_to_one :uptime_check
  many_to_one :notification_channel, class: :MonitoringNotificationChannel, key: :notification_channel_id
  one_to_many :monitoring_incidents
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, etc_type: true

  def path
    "/monitoring/alerts/#{name}"
  end

  def display_condition
    {
      "down" => "Service is down",
      "status_not_expected" => "Status changed",
      "latency_ms_gt" => "Latency above #{threshold.to_i} ms",
      "metric_gt" => "Metric above threshold",
      "log_match" => "Log pattern matched"
    }.fetch(condition, condition)
  end

  def open_incident!(message)
    incident = MonitoringIncident.where(project_id:, monitoring_alert_id: id, status: ["open", "acknowledged"]).first
    return incident if incident

    incident = MonitoringIncident.create(
      project_id:,
      monitoring_alert_id: id,
      uptime_check_id: uptime_check_id,
      title: name,
      severity:,
      message:,
      status: "open"
    )
    update(last_triggered_at: Time.now, updated_at: Time.now)
    notification_channel&.deliver!(incident)
    incident
  rescue => ex
    Clog.emit("Monitoring alert notification failed", Util.exception_to_hash(ex).merge(monitoring_alert_id: id))
    incident
  end

  def ensure_billing_record!
    rate = BillingRate.from_resource_properties("MonitoringAlert", "standard", "global")
    fail "Monitoring alert billing rate is not configured" unless rate
    return if active_billing_records_dataset.where(billing_rate_id: rate.fetch("id")).first

    BillingRecord.create(
      project_id: project_id,
      resource_id: id,
      resource_name: name,
      amount: 1,
      billing_rate_id: rate.fetch("id"),
      resource_tags: Sequel.pg_jsonb_wrap({"service" => "monitoring-alert", "resource_type" => resource_type})
    )
  end

  def self.ensure_default_for_uptime_check(uptime_check)
    where(project_id: uptime_check.project_id, uptime_check_id: uptime_check.id, name: "#{uptime_check.name}-down").first ||
      create(
        project_id: uptime_check.project_id,
        uptime_check_id: uptime_check.id,
        name: "#{uptime_check.name}-down",
        resource_type: "uptime",
        condition: "down",
        severity: "critical"
      )
  end
end

# Table: monitoring_alert
