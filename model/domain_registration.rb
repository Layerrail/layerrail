# frozen_string_literal: true

require_relative "../model"
require "uri"

class DomainRegistration < Sequel::Model(:domain_registration)
  STATUSES = %w[cart pending_payment registering active failed cancelled].freeze
  PROVIDERS = %w[namesilo].freeze
  ABUSE_STATUSES = %w[clear review locked].freeze
  FORWARDING_TYPES = %w[301 302 masked].freeze
  DOMAIN_PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  many_to_one :project, read_only: true
  many_to_one :dns_zone, read_only: true
  many_to_one :contact_profile, class: :DomainContactProfile, read_only: true
  many_to_one :deploy_app, read_only: true
  one_to_many :domain_orders
  one_to_many :domain_bundles
  one_to_one :strand, key: :id

  plugin ResourceMethods

  def self.normalize_domain(domain)
    domain.to_s.strip.downcase.delete_suffix(".")
  end

  def self.valid_domain?(domain)
    DOMAIN_PATTERN.match?(normalize_domain(domain))
  end

  def self.validate_domain!(domain)
    return if valid_domain?(domain)

    fail Validation::ValidationFailed.new({domain: "must be a valid domain name"})
  end

  def self.amount_for_years(registration_price_cents, years)
    registration_price_cents.to_i * years.to_i
  end

  def path
    "/domain/#{ubid}"
  end

  def display_state
    status.tr("_", " ")
  end

  def amount_label
    "$#{format("%0.2f", amount_cents.to_i / 100.0)}"
  end

  def unit_price_label
    "$#{format("%0.2f", registration_price_cents.to_i / 100.0)}/yr"
  end

  def active?
    status == "active"
  end

  def locked_for_abuse?
    abuse_status == "locked"
  end

  def under_abuse_review?
    abuse_status == "review"
  end

  def abuse_label
    abuse_status.to_s.tr("_", " ")
  end

  def forwarding_label
    return "Off" unless forwarding_enabled

    "#{forwarding_type || "302"} to #{forwarding_url}"
  end

  def dnssec_label
    dnssec_enabled ? "#{dnssec_records.to_a.length} record#{dnssec_records.to_a.length == 1 ? "" : "s"}" : "Off"
  end

  def project_attachment_label
    project_attached_at ? "Attached" : "Not attached"
  end

  def deploy_attachment_label
    deploy_app ? deploy_app.name : "Not attached"
  end

  def team_policy_label(key)
    team_policy.to_h.fetch(key.to_s, "project_admin").tr("_", " ")
  end

  def notifications_label
    notifications_enabled ? "On" : "Off"
  end

  def next_auto_renewal_label
    next_auto_renewal_at ? next_auto_renewal_at.strftime("%Y-%m-%d") : "-"
  end

  def auto_renewal_due_at
    return nil unless expires_at

    expires_at - (30 * 24 * 60 * 60)
  end

  def sync_next_auto_renewal!
    update(next_auto_renewal_at: auto_renew ? auto_renewal_due_at : nil, updated_at: Time.now)
  end

  def attach_to_project_dns_zone!
    zone = DnsZone.ensure_service_zone(project_id:, name: domain)
    update(dns_zone_id: zone&.id, project_attached_at: Time.now, updated_at: Time.now)
    zone
  end

  def detach_from_project_dns_zone!
    update(dns_zone_id: nil, project_attached_at: nil, updated_at: Time.now)
  end

  def attach_to_deploy_app!(app)
    fail Validation::ValidationFailed.new({deploy_app_id: "must belong to this project"}) unless app && app.project_id == project_id

    update(deploy_app_id: app.id, deploy_attached_at: Time.now, updated_at: Time.now)
    app.update(hostname: domain, updated_at: Time.now)
    attach_to_project_dns_zone! unless dns_zone_id
  end

  def detach_from_deploy_app!
    update(deploy_app_id: nil, deploy_attached_at: nil, updated_at: Time.now)
  end

  def update_team_policy!(policy)
    allowed = %w[project_admin project_billing project_member]
    normalized = policy.transform_values { allowed.include?(it.to_s) ? it.to_s : "project_admin" }
    update(team_policy: normalized, updated_at: Time.now)
  end

  def set_auto_renew!(enabled)
    reply = enabled ? NameSiloClient.new.enable_auto_renew(domain) : NameSiloClient.new.disable_auto_renew(domain)
    update(
      auto_renew: enabled,
      next_auto_renewal_at: enabled ? auto_renewal_due_at : nil,
      provider_payload: (provider_payload || {}).merge("auto_renew" => reply),
      updated_at: Time.now
    )
    notify_safely(
      "LayerRail domain auto-renew #{enabled ? "enabled" : "disabled"}: #{domain}",
      ["Auto-renew has been #{enabled ? "enabled" : "disabled"} for #{domain}."]
    )
  end

  def set_forwarding!(enabled:, target_url: nil, forwarding_type: "302")
    parsed_url = URI.parse(target_url.to_s) if enabled
    if enabled && (!%w[http https].include?(parsed_url&.scheme) || parsed_url.host.to_s.empty?)
      fail Validation::ValidationFailed.new({forwarding_url: "must be a valid http:// or https:// URL"})
    end

    reply = enabled ? NameSiloClient.new.forward_domain(domain, target_url:, forwarding_type:) : {}
    update(
      forwarding_enabled: enabled,
      forwarding_url: enabled ? target_url : nil,
      forwarding_type: enabled ? forwarding_type : nil,
      provider_payload: (provider_payload || {}).merge("forwarding" => reply),
      updated_at: Time.now
    )
  rescue URI::InvalidURIError
    fail Validation::ValidationFailed.new({forwarding_url: "must be a valid URL"})
  end

  def add_dnssec_record!(keytag:, algorithm:, digest_type:, digest:)
    record = {
      "keytag" => keytag.to_s.strip,
      "algorithm" => algorithm.to_s.strip,
      "digest_type" => digest_type.to_s.strip,
      "digest" => digest.to_s.strip
    }
    reply = NameSiloClient.new.add_dnssec_record(domain, keytag: record["keytag"], algorithm: record["algorithm"], digest_type: record["digest_type"], digest: record["digest"])
    update(
      dnssec_enabled: true,
      dnssec_records: (dnssec_records.to_a + [record]).uniq,
      provider_payload: (provider_payload || {}).merge("dnssec_add" => reply),
      updated_at: Time.now
    )
  end

  def clear_dnssec_records!
    dnssec_records.to_a.each do |record|
      NameSiloClient.new.delete_dnssec_record(
        domain,
        keytag: record["keytag"],
        algorithm: record["algorithm"],
        digest_type: record["digest_type"],
        digest: record["digest"]
      )
    end
    update(dnssec_enabled: false, dnssec_records: [], updated_at: Time.now)
  end

  def send_domain_notification!(subject, body)
    return unless notifications_enabled

    receivers = project.accounts_dataset.select_map(:email).compact.uniq
    return if receivers.empty?

    Util.send_email(
      receivers,
      subject,
      greeting: "Hi,",
      body:,
      button_title: "View domain",
      button_link: "#{Config.base_url}#{project.path}#{path}",
      author_name: "LayerRail"
    )
    update(last_notification_at: Time.now, updated_at: Time.now)
  end

  def notify_safely(subject, body)
    send_domain_notification!(subject, body)
  rescue => ex
    Clog.emit("domain notification failed", Util.exception_to_hash(ex, into: {domain_notification_failed: {domain_registration_ubid: ubid}}))
  end

  def dns_zone_label
    dns_zone ? dns_zone.name : "Not created yet"
  end

  def expires_at_label
    expires_at ? expires_at.strftime("%Y-%m-%d") : "-"
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_includes(PROVIDERS, :provider)
    validates_includes(ABUSE_STATUSES, :abuse_status) if values.key?(:abuse_status)
    if forwarding_type && !FORWARDING_TYPES.include?(forwarding_type)
      errors.add(:forwarding_type, "must be one of #{FORWARDING_TYPES.join(", ")}")
    end
    errors.add(:domain, "must be a valid domain name") unless self.class.valid_domain?(domain)
    errors.add(:years, "must be between 1 and 10") unless years && years.between?(1, 10)
    errors.add(:amount_cents, "must be zero or greater") unless amount_cents && amount_cents >= 0
  end
end

# Table: domain_registration
# Columns:
#  id                       | uuid                     | PRIMARY KEY
#  project_id               | uuid                     | NOT NULL
#  dns_zone_id              | uuid                     |
#  contact_profile_id       | uuid                     |
#  deploy_app_id            | uuid                     |
#  domain                   | text                     | NOT NULL
#  status                   | text                     | NOT NULL DEFAULT 'cart'::text
#  provider                 | text                     | NOT NULL DEFAULT 'namesilo'::text
#  provider_order_id        | text                     |
#  provider_domain_id       | text                     |
#  checkout_id              | text                     |
#  years                    | integer                  | NOT NULL DEFAULT 1
#  currency                 | text                     | NOT NULL DEFAULT 'usd'::text
#  registration_price_cents | integer                  | NOT NULL DEFAULT 0
#  renewal_price_cents      | integer                  | NOT NULL DEFAULT 0
#  transfer_price_cents     | integer                  | NOT NULL DEFAULT 0
#  discount_cents           | integer                  | NOT NULL DEFAULT 0
#  amount_cents             | integer                  | NOT NULL DEFAULT 0
#  contact_data             | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  provider_payload         | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  failure_message          | text                     |
#  expires_at               | timestamp with time zone |
#  nameservers              | jsonb                    | NOT NULL DEFAULT '[]'::jsonb
#  auto_renew               | boolean                  | NOT NULL DEFAULT false
#  last_renewed_at          | timestamp with time zone |
#  transferred_at           | timestamp with time zone |
#  deploy_attached_at       | timestamp with time zone |
#  team_policy              | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  created_at               | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at               | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  domain_registration_pkey                    | PRIMARY KEY btree (id)
#  domain_registration_project_id_domain_index | UNIQUE btree (project_id, domain)
#  domain_registration_checkout_id_index       | btree (checkout_id)
#  domain_registration_dns_zone_id_index       | btree (dns_zone_id)
#  domain_registration_project_id_status_index | btree (project_id, status)
#  domain_registration_contact_profile_id_index | btree (contact_profile_id)
# Check constraints:
#  valid_domain_registration_amount   | (registration_price_cents >= 0 AND renewal_price_cents >= 0 AND transfer_price_cents >= 0 AND discount_cents >= 0 AND amount_cents >= 0)
#  valid_domain_registration_provider | (provider = 'namesilo'::text)
#  valid_domain_registration_status   | (status = ANY (ARRAY['cart'::text, 'pending_payment'::text, 'registering'::text, 'active'::text, 'failed'::text, 'cancelled'::text]))
#  valid_domain_registration_years    | (years >= 1 AND years <= 10)
# Foreign key constraints:
#  domain_registration_contact_profile_id_fkey | (contact_profile_id) REFERENCES domain_contact_profile(id) ON DELETE SET NULL
#  domain_registration_dns_zone_id_fkey | (dns_zone_id) REFERENCES dns_zone(id) ON DELETE SET NULL
#  domain_registration_project_id_fkey  | (project_id) REFERENCES project(id)
