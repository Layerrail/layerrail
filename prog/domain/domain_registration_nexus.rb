# frozen_string_literal: true

module Prog::Domain
end

class Prog::Domain::DomainRegistrationNexus < Prog::Base
  subject_is :domain_registration

  def self.assemble(domain_registration)
    Strand.create_with_id(domain_registration, prog: "Domain::DomainRegistrationNexus", label: "start")
  rescue Sequel::UniqueConstraintViolation
    domain_registration.strand
  end

  label def start
    register_deadline(nil, 10 * 60)
    fail "Domains are not enabled" unless Config.domains_enabled
    fail "NameSilo is not configured" unless NameSiloClient.configured?

    domain_registration.update(status: "registering", failure_message: nil, updated_at: Time.now)
    availability = client.check_register_availability(domain_registration.domain)
    fail "#{domain_registration.domain} is no longer available" unless availability[:available]
    sync_contact_profile if domain_registration.contact_profile

    reply = client.register_domain(domain_registration)
    nameserver_reply = client.change_nameservers(domain_registration.domain, domain_registration.nameservers)
    zone = DnsZone.ensure_service_zone(project_id: domain_registration.project_id, name: domain_registration.domain)
    provider_payload = domain_registration.provider_payload || {}
    provider_payload = provider_payload.merge(
      "availability" => availability[:raw],
      "registration" => reply,
      "nameservers" => nameserver_reply
    )

    domain_registration.update(
      status: "active",
      dns_zone_id: zone&.id,
      project_attached_at: Time.now,
      provider_order_id: reply["order_id"] || reply["orderid"] || reply.dig("order", "id"),
      provider_domain_id: reply["domain_id"] || reply["domainid"] || reply.dig("domain", "id"),
      provider_payload:,
      expires_at: Time.now + (domain_registration.years * 365 * 24 * 60 * 60),
      next_auto_renewal_at: domain_registration.auto_renew ? Time.now + ((domain_registration.years * 365 - 30) * 24 * 60 * 60) : nil,
      updated_at: Time.now
    )

    begin
      domain_registration.reload.send_domain_notification!(
        "LayerRail domain active: #{domain_registration.domain}",
        [
          "#{domain_registration.domain} is now active.",
          "A LayerRail DNS zone has been created and attached to your project."
        ]
      )
    rescue => ex
      Clog.emit("domain registration notification failed", Util.exception_to_hash(ex, into: {domain_registration_notification_failed: {domain_registration_ubid: domain_registration.ubid}}))
    end

    Clog.emit("NameSilo domain registered", {namesilo_domain_registered: {domain_registration_ubid: domain_registration.ubid, domain: domain_registration.domain}})
    pop "domain registered"
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    message = ex.message.to_s[0, 1000]
    domain_registration&.update(status: "failed", failure_message: message, updated_at: Time.now)
    domain_registration&.notify_safely(
      "LayerRail domain registration failed: #{domain_registration.domain}",
      [
        "#{domain_registration.domain} could not be registered automatically.",
        "Reason: #{message}",
        "Open the domain in LayerRail to review the failure and retry."
      ]
    )
    Clog.emit("NameSilo domain registration failed", Util.exception_to_hash(ex, into: {namesilo_domain_registration_failed: {domain_registration_ubid: domain_registration&.ubid}}))
    pop "domain registration failed"
  end

  private

  def client
    @client ||= NameSiloClient.new
  end

  def sync_contact_profile
    contact_profile = domain_registration.contact_profile
    return if contact_profile.provider_contact_id

    reply, contact_id = client.create_contact_profile(contact_profile)
    contact_profile.update(
      provider_contact_id: contact_id,
      provider_payload: (contact_profile.provider_payload || {}).merge("contact_add" => reply),
      updated_at: Time.now
    )
  end
end
