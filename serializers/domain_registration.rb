# frozen_string_literal: true

class Serializers::DomainRegistration < Serializers::Base
  def self.serialize_internal(domain, options = {})
    base = {
      id: domain.ubid,
      domain: domain.domain,
      state: domain.display_state,
      years: domain.years,
      currency: domain.currency,
      registration_price_cents: domain.registration_price_cents,
      renewal_price_cents: domain.renewal_price_cents,
      transfer_price_cents: domain.transfer_price_cents,
      amount_cents: domain.amount_cents,
      auto_renew: domain.auto_renew,
      expires_at: domain.expires_at,
      dns_zone: domain.dns_zone&.name,
      contact_profile_id: domain.contact_profile&.ubid,
      deploy_app_id: domain.deploy_app&.ubid,
      nameservers: domain.nameservers.to_a,
      created_at: domain.created_at,
      updated_at: domain.updated_at
    }

    if options[:detailed]
      base.merge!(
        forwarding: {
          enabled: domain.forwarding_enabled,
          url: domain.forwarding_url,
          type: domain.forwarding_type
        },
        dnssec: {
          enabled: domain.dnssec_enabled,
          records: domain.dnssec_records.to_a
        },
        abuse_status: domain.abuse_status,
        team_policy: domain.team_policy.to_h,
        provider_domain_id: domain.provider_domain_id,
        failure_message: domain.failure_message
      )
    end

    base
  end
end
