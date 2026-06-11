# frozen_string_literal: true

module Prog::Domain
end

class Prog::Domain::DomainOrderNexus < Prog::Base
  subject_is :domain_order

  def self.assemble(domain_order)
    Strand.create_with_id(domain_order, prog: "Domain::DomainOrderNexus", label: "start")
  rescue Sequel::UniqueConstraintViolation
    domain_order.strand
  end

  label def start
    register_deadline(nil, 10 * 60)
    fail "Domains are not enabled" unless Config.domains_enabled
    fail "NameSilo is not configured" unless NameSiloClient.configured?

    case domain_order.kind
    when "renewal"
      process_renewal
    when "transfer"
      process_transfer
    else
      fail "Unsupported domain order kind: #{domain_order.kind}"
    end

    pop "domain order processed"
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    domain_order&.update(status: "failed", failure_message: ex.message.to_s[0, 1000], updated_at: Time.now)
    Clog.emit("NameSilo domain order failed", Util.exception_to_hash(ex, into: {namesilo_domain_order_failed: {domain_order_ubid: domain_order&.ubid}}))
    pop "domain order failed"
  end

  private

  def process_renewal
    registration = domain_order.domain_registration || fail("Domain registration is missing")
    reply = client.renew_domain(domain_order)
    registration.update(
      expires_at: (registration.expires_at || Time.now) + (domain_order.years * 365 * 24 * 60 * 60),
      last_renewed_at: Time.now,
      next_auto_renewal_at: registration.auto_renew ? ((registration.expires_at || Time.now) + (domain_order.years * 365 * 24 * 60 * 60) - (30 * 24 * 60 * 60)) : nil,
      updated_at: Time.now
    )
    notify_domain(registration, "LayerRail domain renewed: #{registration.domain}", ["#{registration.domain} was renewed for #{domain_order.years} year#{domain_order.years == 1 ? "" : "s"}." ])
    finish_with(reply)
  end

  def process_transfer
    reply = client.transfer_domain(domain_order)
    registration = domain_order.domain_registration || DomainRegistration.new_with_id(
      project_id: domain_order.project_id,
      contact_profile_id: domain_order.domain_contact_profile_id,
      domain: domain_order.domain,
      status: "active",
      provider: "namesilo",
      years: domain_order.years,
      currency: domain_order.currency,
      registration_price_cents: 0,
      renewal_price_cents: 0,
      transfer_price_cents: domain_order.amount_cents,
      discount_cents: 0,
      amount_cents: 0,
      provider_payload: {}
    ).save_changes

    zone = DnsZone.ensure_service_zone(project_id: registration.project_id, name: registration.domain)
    registration.update(
      status: "active",
      dns_zone_id: zone&.id,
      project_attached_at: Time.now,
      transferred_at: Time.now,
      provider_payload: (registration.provider_payload || {}).merge("transfer" => reply),
      expires_at: Time.now + (domain_order.years * 365 * 24 * 60 * 60),
      updated_at: Time.now
    )
    domain_order.update(domain_registration_id: registration.id)
    notify_domain(registration, "LayerRail domain transfer started: #{registration.domain}", ["#{registration.domain} has been accepted by the registrar transfer flow and is now visible in LayerRail."])
    finish_with(reply)
  end

  def finish_with(reply)
    domain_order.update(
      status: "succeeded",
      provider_order_id: reply["order_id"] || reply["orderid"] || reply.dig("order", "id"),
      provider_payload: (domain_order.provider_payload || {}).merge("provider_reply" => reply),
      completed_at: Time.now,
      updated_at: Time.now
    )
    Clog.emit("NameSilo domain order processed", {namesilo_domain_order_processed: {domain_order_ubid: domain_order.ubid, kind: domain_order.kind, domain: domain_order.domain}})
  end

  def notify_domain(registration, subject, body)
    registration.send_domain_notification!(subject, body)
  rescue => ex
    Clog.emit("domain order notification failed", Util.exception_to_hash(ex, into: {domain_order_notification_failed: {domain_order_ubid: domain_order.ubid, domain_registration_ubid: registration.ubid}}))
  end

  def client
    @client ||= NameSiloClient.new
  end
end
