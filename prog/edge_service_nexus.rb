# frozen_string_literal: true

require "uri"

class Prog::EdgeServiceNexus < Prog::Base
  subject_is :edge_service

  def self.assemble(edge_service)
    Strand.create_with_id(edge_service, prog: "EdgeServiceNexus", label: "start", stack: [{subject_id: edge_service.id}])
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
    nap 6 * 60 * 60
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
      content: Config.edge_proxy_hostname
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
