# frozen_string_literal: true

module Prog::Domain
end

class Prog::Domain::AutoRenewDomains < Prog::Base
  label def wait
    due_domains = DomainRegistration
      .where(status: "active", auto_renew: true)
      .where { next_auto_renewal_at <= Sequel::CURRENT_TIMESTAMP }
      .limit(50)
      .all

    due_domains.each do |domain_registration|
      next if domain_registration.locked_for_abuse?
      next if DomainOrder.where(domain_registration_id: domain_registration.id, kind: "renewal", status: %w[cart pending_payment processing]).any?

      DB.transaction do
        order = DomainOrder.new_with_id(
          project_id: domain_registration.project_id,
          domain_registration_id: domain_registration.id,
          domain_contact_profile_id: domain_registration.contact_profile_id,
          kind: "renewal",
          status: "cart",
          provider: domain_registration.provider,
          domain: domain_registration.domain,
          years: 1,
          currency: domain_registration.currency,
          amount_cents: domain_registration.renewal_price_cents,
          scheduled_by_automation: true,
          due_at: domain_registration.next_auto_renewal_at
        )
        order.save_changes
        domain_registration.update(next_auto_renewal_at: nil, updated_at: Time.now)
      end

      notify_auto_renewal(domain_registration)
    end

    nap 6 * 60 * 60
  end

  private

  def notify_auto_renewal(domain_registration)
    domain_registration.send_domain_notification!(
      "LayerRail domain renewal ready: #{domain_registration.domain}",
      [
        "#{domain_registration.domain} is inside the renewal window.",
        "A renewal order has been added to your domain cart. Complete checkout to renew it with the registrar."
      ]
    )
  rescue => ex
    Clog.emit("domain auto-renew notification failed", Util.exception_to_hash(ex, into: {domain_auto_renew_notification_failed: {domain_registration_ubid: domain_registration.ubid}}))
  end
end
