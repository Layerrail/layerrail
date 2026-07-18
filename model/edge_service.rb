# frozen_string_literal: true

require_relative "../model"

class EdgeService < Sequel::Model
  many_to_one :project
  one_to_one :strand, key: :id
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, etc_type: true
  plugin SemaphoreMethods, :destroy, :usage_limit_suspended, :usage_limit_resume

  CACHE_MODES = {
    "standard" => "Standard",
    "aggressive" => "Aggressive",
    "bypass" => "Bypass"
  }.freeze

  TLS_MODES = {
    "full" => "Full",
    "strict" => "Strict"
  }.freeze

  def path
    "/edge/#{name}"
  end

  def ready?
    state == "ready" && !usage_limit_suspended_set?
  end

  def display_cache_mode
    CACHE_MODES.fetch(cache_mode, cache_mode)
  end

  def display_tls_mode
    TLS_MODES.fetch(tls_mode, tls_mode)
  end

  def ensure_billing_record!
    rate = BillingRate.from_resource_properties("EdgeService", "standard", "global")
    fail "Edge billing rate is not configured" unless rate
    return if active_billing_records_dataset.where(billing_rate_id: rate.fetch("id")).first

    BillingRecord.create(
      project_id: project_id,
      resource_id: id,
      resource_name: name,
      amount: 1,
      billing_rate_id: rate.fetch("id"),
      resource_tags: Sequel.pg_jsonb_wrap({"service" => "edge", "hostname" => hostname})
    )
  end

  def self.generate_hostname(project, name)
    "#{project.ubid}-#{name}.edge.layerrail.com".downcase.gsub(/[^a-z0-9.-]/, "-")
  end
end

# Table: edge_service
