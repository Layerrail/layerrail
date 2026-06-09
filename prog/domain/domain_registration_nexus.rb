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

    reply = client.register_domain(domain_registration)
    provider_payload = domain_registration.provider_payload || {}
    provider_payload = provider_payload.merge(
      "availability" => availability[:raw],
      "registration" => reply
    )

    domain_registration.update(
      status: "active",
      provider_order_id: reply["order_id"] || reply["orderid"] || reply.dig("order", "id"),
      provider_domain_id: reply["domain_id"] || reply["domainid"] || reply.dig("domain", "id"),
      provider_payload:,
      expires_at: Time.now + (domain_registration.years * 365 * 24 * 60 * 60),
      updated_at: Time.now
    )

    Clog.emit("NameSilo domain registered", {namesilo_domain_registered: {domain_registration_ubid: domain_registration.ubid, domain: domain_registration.domain}})
    pop "domain registered"
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    domain_registration&.update(status: "failed", failure_message: ex.message.to_s[0, 1000], updated_at: Time.now)
    Clog.emit("NameSilo domain registration failed", Util.exception_to_hash(ex, into: {namesilo_domain_registration_failed: {domain_registration_ubid: domain_registration&.ubid}}))
    pop "domain registration failed"
  end

  private

  def client
    @client ||= NameSiloClient.new
  end
end
