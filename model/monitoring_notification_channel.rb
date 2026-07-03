# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../model"

class MonitoringNotificationChannel < Sequel::Model
  many_to_one :project
  one_to_many :monitoring_alerts

  plugin ResourceMethods, etc_type: true

  def path
    "/monitoring/notification-channels/#{name}"
  end

  def display_kind
    kind == "email" ? "Email" : "Webhook"
  end

  def deliver!(incident)
    return unless enabled

    case kind
    when "email"
      button_link = incident.id ? "#{Config.base_url}#{project.path}#{incident.path}" : "#{Config.base_url}#{project.path}/monitoring"
      Util.send_email(
        target,
        "[LayerRail] #{incident.severity.capitalize} incident: #{incident.title}",
        greeting: "Monitoring alert",
        body: [
          incident.message,
          "Project: #{project.name}",
          "Status: #{incident.status}",
          "Opened: #{incident.opened_at}"
        ].compact.join("\n\n"),
        button_title: "Open incident",
        button_link:
      )
    when "webhook"
      uri = URI(target)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = JSON.generate({
        event: "monitoring.incident.opened",
        project: project.ubid,
        incident: incident.id ? incident.ubid : nil,
        title: incident.title,
        severity: incident.severity,
        status: incident.status,
        message: incident.message,
        opened_at: incident.opened_at
      })
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 10, open_timeout: 5) do |http|
        response = http.request(req)
        fail "Webhook returned HTTP #{response.code}" unless response.code.to_i.between?(200, 299)
      end
    end
    update(last_tested_at: Time.now, last_error: nil, updated_at: Time.now)
  rescue => ex
    update(last_error: ex.message, updated_at: Time.now)
    raise
  end

  def deliver_test!
    incident = MonitoringIncident.new(
      project_id: project_id,
      title: "LayerRail monitoring test",
      severity: "info",
      status: "open",
      message: "This is a test notification from LayerRail Monitoring.",
      opened_at: Time.now
    )
    deliver!(incident)
  end
end

# Table: monitoring_notification_channel
