# frozen_string_literal: true

require_relative "../model"

class MonitoringIncident < Sequel::Model
  many_to_one :project
  many_to_one :monitoring_alert
  many_to_one :uptime_check

  plugin ResourceMethods, etc_type: true

  def path
    "/monitoring/incidents/#{ubid}"
  end

  def open?
    status == "open"
  end

  def acknowledged?
    status == "acknowledged"
  end

  def resolved?
    status == "resolved"
  end

  def acknowledge!
    update(status: "acknowledged", acknowledged_at: Time.now, updated_at: Time.now) unless resolved?
  end

  def resolve!
    update(status: "resolved", resolved_at: Time.now, updated_at: Time.now)
  end
end

# Table: monitoring_incident
