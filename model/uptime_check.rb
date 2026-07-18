# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "../model"

class UptimeCheck < Sequel::Model
  many_to_one :project
  one_to_one :strand, key: :id
  one_to_many :monitoring_alerts
  one_to_many :monitoring_incidents
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, etc_type: true
  plugin SemaphoreMethods, :destroy

  def path
    "/monitoring/uptime/#{name}"
  end

  def up?
    state == "up"
  end

  def down?
    state == "down"
  end

  def paused?
    !enabled || state == "paused"
  end

  def run_check!
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    uri = SafeHttp.validate_url!(target_url, allowed_schemes: %w[http https])
    klass = (self[:method] == "HEAD") ? Net::HTTP::Head : Net::HTTP::Get
    request = klass.new(uri)
    response = nil
    SafeHttp.start(uri, allowed_schemes: %w[http https], read_timeout: timeout_seconds, open_timeout: timeout_seconds) do |http|
      http.request(request) { |upstream_response| response = upstream_response }
    end
    latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    ok = response.code.to_i == expected_status
    update(
      state: ok ? "up" : "down",
      last_checked_at: Time.now,
      last_status_code: response.code.to_i,
      last_latency_ms: latency,
      last_error: ok ? nil : "Expected HTTP #{expected_status}, received #{response.code}",
      updated_at: Time.now,
    )
    ok
  rescue => ex
    update(
      state: "down",
      last_checked_at: Time.now,
      last_error: ex.message,
      updated_at: Time.now,
    )
    false
  end

  def evaluate_alerts!
    return if up?

    alerts = monitoring_alerts_dataset.where(enabled: true).all
    alerts = [MonitoringAlert.ensure_default_for_uptime_check(self)] if alerts.empty?
    alerts.each do |alert|
      alert.ensure_billing_record!
      alert.open_incident!("Uptime check #{name} is down: #{last_error || "no response"}")
    end
  end

  def ensure_billing_record!
    rate = BillingRate.from_resource_properties("MonitoringUptimeCheck", "standard", "global")
    fail "Uptime check billing rate is not configured" unless rate
    return if active_billing_records_dataset.where(billing_rate_id: rate.fetch("id")).first

    BillingRecord.create(
      project_id:,
      resource_id: id,
      resource_name: name,
      amount: 1,
      billing_rate_id: rate.fetch("id"),
      resource_tags: Sequel.pg_jsonb_wrap({"service" => "uptime-check", "target_url" => target_url}),
    )
  end
end

# Table: uptime_check
