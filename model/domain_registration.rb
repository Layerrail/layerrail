# frozen_string_literal: true

require_relative "../model"

class DomainRegistration < Sequel::Model(:domain_registration)
  STATUSES = %w[cart pending_payment registering active failed cancelled].freeze
  PROVIDERS = %w[namesilo].freeze
  DOMAIN_PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  many_to_one :project, read_only: true
  many_to_one :dns_zone, read_only: true
  many_to_one :contact_profile, class: :DomainContactProfile, read_only: true
  one_to_many :domain_orders
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
