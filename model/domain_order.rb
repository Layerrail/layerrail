# frozen_string_literal: true

require_relative "../model"

class DomainOrder < Sequel::Model(:domain_order)
  KINDS = %w[renewal transfer].freeze
  STATUSES = %w[cart pending_payment processing succeeded failed cancelled].freeze
  PROVIDERS = %w[namesilo].freeze

  many_to_one :project, read_only: true
  many_to_one :domain_registration, read_only: true
  many_to_one :domain_contact_profile, read_only: true
  one_to_one :strand, key: :id

  plugin ResourceMethods

  def path
    "/domain/order/#{ubid}"
  end

  def display_state
    status.tr("_", " ")
  end

  def display_kind
    kind.tr("_", " ")
  end

  def amount_label
    "$#{format("%0.2f", amount_cents.to_i / 100.0)}"
  end

  def completed_at_label
    completed_at ? completed_at.strftime("%Y-%m-%d") : "-"
  end

  def due_at_label
    due_at ? due_at.strftime("%Y-%m-%d") : "-"
  end

  def validate
    super
    validates_includes(KINDS, :kind)
    validates_includes(STATUSES, :status)
    validates_includes(PROVIDERS, :provider)
    errors.add(:domain, "must be a valid domain name") unless DomainRegistration.valid_domain?(domain)
    errors.add(:years, "must be between 1 and 10") unless years && years.between?(1, 10)
    errors.add(:amount_cents, "must be zero or greater") unless amount_cents && amount_cents >= 0
    errors.add(:auth_code, "is required for transfers") if kind == "transfer" && auth_code.to_s.empty?
  end
end

# Table: domain_order
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  project_id                | uuid                     | NOT NULL
#  domain_registration_id    | uuid                     |
#  domain_contact_profile_id | uuid                     |
#  kind                      | text                     | NOT NULL
#  status                    | text                     | NOT NULL DEFAULT 'cart'::text
#  provider                  | text                     | NOT NULL DEFAULT 'namesilo'::text
#  domain                    | text                     | NOT NULL
#  years                     | integer                  | NOT NULL DEFAULT 1
#  currency                  | text                     | NOT NULL DEFAULT 'usd'::text
#  amount_cents              | integer                  | NOT NULL DEFAULT 0
#  checkout_id               | text                     |
#  auth_code                 | text                     |
#  provider_order_id         | text                     |
#  provider_payload          | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  failure_message           | text                     |
#  created_at                | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at                | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  scheduled_by_automation   | boolean                  | NOT NULL DEFAULT false
#  due_at                    | timestamp with time zone |
#  completed_at              | timestamp with time zone |
# Indexes:
#  domain_order_pkey                         | PRIMARY KEY btree (id)
#  domain_order_checkout_id_index            | btree (checkout_id)
#  domain_order_domain_registration_id_index | btree (domain_registration_id)
#  domain_order_due_at_index                 | btree (due_at)
#  domain_order_project_id_domain_index      | btree (project_id, domain)
#  domain_order_project_id_status_index      | btree (project_id, status)
# Check constraints:
#  valid_domain_order_amount   | (amount_cents >= 0)
#  valid_domain_order_kind     | (kind = ANY (ARRAY['renewal'::text, 'transfer'::text]))
#  valid_domain_order_provider | (provider = 'namesilo'::text)
#  valid_domain_order_status   | (status = ANY (ARRAY['cart'::text, 'pending_payment'::text, 'processing'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text]))
#  valid_domain_order_years    | (years >= 1 AND years <= 10)
# Foreign key constraints:
#  domain_order_domain_contact_profile_id_fkey | (domain_contact_profile_id) REFERENCES domain_contact_profile(id) ON DELETE SET NULL
#  domain_order_domain_registration_id_fkey    | (domain_registration_id) REFERENCES domain_registration(id) ON DELETE SET NULL
#  domain_order_project_id_fkey                | (project_id) REFERENCES project(id)
