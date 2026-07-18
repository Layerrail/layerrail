# frozen_string_literal: true

require "uri"

class Prog::EdgeServiceNexus < Prog::Base
  subject_is :edge_service

  USAGE_LIMIT_LABELS = %w[usage_limit_suspend usage_limit_suspended usage_limit_resume destroy].freeze

  def self.assemble(edge_service)
    Strand.create_with_id(edge_service, prog: "EdgeServiceNexus", label: "start", stack: [{subject_id: edge_service.id}])
  end

  def before_run
    super
    return unless usage_limit_suspended_set?
    return if USAGE_LIMIT_LABELS.include?(strand.label)

    hop_usage_limit_suspend if edge_service.state == "ready"
    nap 5 * 60
  end

  label def start
    when_destroy_set? { hop_destroy }
    sync_dns_record
    edge_service.update(state: "ready", last_error: nil, updated_at: Time.now)
    edge_service.ensure_billing_record!
    hop_wait
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    edge_service.update(state: "failed", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Edge service provision failed", Util.exception_to_hash(ex).merge(edge_service_id: edge_service.id))
    nap 30 * 60
  end

  label def wait
    when_destroy_set? { hop_destroy }
    when_usage_limit_suspended_set? { hop_usage_limit_suspend }
    decr_usage_limit_resume if usage_limit_resume_set?
    nap 6 * 60 * 60
  end

  label def usage_limit_suspend
    delete_dns_record
    edge_service.update(state: "suspended", last_error: nil, updated_at: Time.now)
    hop_usage_limit_suspended
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    edge_service.update(last_error: ex.message, updated_at: Time.now)
    Clog.emit("Edge service usage-limit suspension failed", Util.exception_to_hash(ex).merge(edge_service_id: edge_service.id))
    nap 5 * 60
  end

  label def usage_limit_suspended
    when_destroy_set? { hop_destroy }
    when_usage_limit_resume_set? { hop_usage_limit_resume } unless usage_limit_suspended_set?
    nap 6 * 60 * 60
  end

  label def usage_limit_resume
    sync_dns_record
    decr_usage_limit_resume
    edge_service.update(state: "ready", last_error: nil, updated_at: Time.now)
    edge_service.ensure_billing_record!
    hop_wait
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    edge_service.update(last_error: ex.message, updated_at: Time.now)
    Clog.emit("Edge service usage-limit resume failed", Util.exception_to_hash(ex).merge(edge_service_id: edge_service.id))
    nap 5 * 60
  end

  label def destroy
    decr_destroy
    edge_service.update(state: "deleting", updated_at: Time.now)
    delete_dns_record
    BillingRecord.finalize_active_for_resource(edge_service)
    edge_service.destroy
    pop "edge service destroyed"
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    edge_service.update(state: "failed", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Edge service delete failed", Util.exception_to_hash(ex).merge(edge_service_id: edge_service.id))
    nap 30 * 60
  end

  private

  def sync_dns_record
    return unless CloudflareDnsClient.configured?

    CloudflareDnsClient.new.upsert_record(
      name: edge_service.hostname,
      type: "CNAME",
      ttl: 300,
      content: Config.edge_proxy_hostname,
      proxied: true
    )
  end

  def delete_dns_record
    return unless CloudflareDnsClient.configured?

    CloudflareDnsClient.new.delete_record(
      name: edge_service.hostname,
      type: "CNAME",
      content: Config.edge_proxy_hostname
    )
  end
end
