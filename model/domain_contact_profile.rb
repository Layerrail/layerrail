# frozen_string_literal: true

require_relative "../model"

class DomainContactProfile < Sequel::Model(:domain_contact_profile)
  PROVIDERS = %w[namesilo].freeze

  many_to_one :project, read_only: true
  one_to_many :domain_registrations, key: :contact_profile_id
  one_to_many :domain_orders

  plugin ResourceMethods

  def path
    "/domain/contact-profile/#{ubid}"
  end

  def label
    "#{name} - #{email}"
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def to_namesilo_params
    {
      fn: first_name,
      ln: last_name,
      ad: address1,
      ad2: address2,
      cy: city,
      st: state,
      zp: postal_code,
      ct: country_code,
      em: email,
      ph: phone,
      cp: organization
    }.compact
  end

  def validate
    super
    validates_includes(PROVIDERS, :provider)
    validates_presence %i[name first_name last_name email phone address1 city state postal_code country_code]
    validates_format(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, :email, message: "must be a valid email")
    validates_format(/\A[A-Z]{2}\z/i, :country_code, message: "must be a 2-letter country code")
    errors.add(:country_code, "must be a supported country") if country_code && !ISO3166::Country[country_code]
    validates_format(/\A\+\d{1,3}[.\-\s]?\d[\d.\-\s]{5,18}\z/, :phone, message: "must include country code, like +1.5551234567")
  end
end

# Table: domain_contact_profile
# Columns:
#  id                  | uuid                     | PRIMARY KEY
#  project_id          | uuid                     | NOT NULL
#  name                | text                     | NOT NULL
#  first_name          | text                     | NOT NULL
#  last_name           | text                     | NOT NULL
#  organization        | text                     |
#  email               | text                     | NOT NULL
#  phone               | text                     | NOT NULL
#  address1            | text                     | NOT NULL
#  address2            | text                     |
#  city                | text                     | NOT NULL
#  state               | text                     | NOT NULL
#  postal_code         | text                     | NOT NULL
#  country_code        | text                     | NOT NULL
#  provider            | text                     | NOT NULL DEFAULT 'namesilo'::text
#  provider_contact_id | text                     |
#  provider_payload    | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  created_at          | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at          | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  domain_contact_profile_pkey                  | PRIMARY KEY btree (id)
#  domain_contact_profile_project_id_name_index | UNIQUE btree (project_id, name)
#  domain_contact_profile_provider_contact_id_index | btree (provider_contact_id)
# Check constraints:
#  valid_domain_contact_profile_provider | (provider = 'namesilo'::text)
# Foreign key constraints:
#  domain_contact_profile_project_id_fkey | (project_id) REFERENCES project(id)
