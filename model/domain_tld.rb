# frozen_string_literal: true

require_relative "../model"
require "set"

class DomainTld < Sequel::Model(:domain_tld)
  PROVIDERS = %w[namesilo domainnameapi centralnic openprovider].freeze
  TLD_LABEL_PATTERN = /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/
  TLD_PATTERN = /\A#{TLD_LABEL_PATTERN}(?:\.#{TLD_LABEL_PATTERN})*\z/

  plugin ResourceMethods

  def self.normalize_tld(tld)
    tld.to_s.strip.downcase.delete_prefix(".")
  end

  def self.valid_tld_name?(tld)
    TLD_PATTERN.match?(normalize_tld(tld))
  end

  def self.matching_tld_for_domain(domain, candidate_tlds: nil)
    domain = DomainRegistration.normalize_domain(domain)
    labels = domain.split(".")
    return nil if labels.length < 2

    suffixes = (1...labels.length).map { |index| labels[index..].join(".") }
    candidates = candidate_tlds ? candidate_tlds.map { normalize_tld(it) }.to_set : select_map(:tld).map { normalize_tld(it) }.to_set
    suffixes.select { candidates.include?(it) }.max_by(&:length)
  end

  def self.requested_tld_for_domain(domain)
    labels = DomainRegistration.normalize_domain(domain).split(".")
    return labels.last.to_s if labels.length < 2

    labels[1..].join(".")
  end

  def self.enabled_for_domain?(domain)
    tld = matching_tld_for_domain(domain) || requested_tld_for_domain(domain)
    row = first(tld:)
    row.nil? || row.enabled
  end

  def self.apply_admin_pricing(domain, provider_pricing)
    return provider_pricing if provider_pricing[:tld_enabled] == false

    tld = matching_tld_for_domain(domain) || provider_pricing[:tld] || requested_tld_for_domain(domain)
    row = first(tld:)
    return provider_pricing.merge(tld_enabled: true) unless row
    return provider_pricing.merge(tld_enabled: false) unless row.enabled

    registration_price_cents = row.registration_price_cents.positive? ? row.registration_price_cents : provider_pricing[:registration_price_cents]
    renewal_price_cents = row.renewal_price_cents.positive? ? row.renewal_price_cents : provider_pricing[:renewal_price_cents]
    transfer_price_cents = row.transfer_price_cents.positive? ? row.transfer_price_cents : provider_pricing[:transfer_price_cents]
    provider_pricing.merge(
      tld_enabled: true,
      registration_price_cents:,
      renewal_price_cents:,
      transfer_price_cents:,
      discount_cents: [provider_pricing[:base_registration_price_cents].to_i - registration_price_cents, 0].max,
      admin_tld: row.values
    )
  end

  def self.sync_from_provider_catalog!(provider:, catalog:)
    now = Time.now
    counts = {created: 0, updated: 0, skipped: 0}

    DB.transaction do
      catalog.each do |item|
        tld = normalize_tld(item.fetch(:tld))
        unless valid_tld_name?(tld)
          counts[:skipped] += 1
          next
        end

        attrs = {
          enabled: true,
          provider:,
          base_registration_price_cents: item[:base_registration_price_cents].to_i,
          base_renewal_price_cents: item[:base_renewal_price_cents].to_i,
          base_transfer_price_cents: item[:base_transfer_price_cents].to_i,
          provider_payload: {
            "source" => "provider_sync",
            "provider" => provider,
            "raw" => item[:raw] || {}
          },
          updated_at: now
        }

        row = first(tld:)
        if row
          manual_override = row.provider_payload.to_h["manual_override"] || (row.provider_payload.to_h["source"] != "provider_sync" && %i[registration_price_cents renewal_price_cents transfer_price_cents].any? { |column| row[column].to_i.positive? })
          attrs.merge!(
            registration_price_cents: item[:registration_price_cents].to_i,
            renewal_price_cents: item[:renewal_price_cents].to_i,
            transfer_price_cents: item[:transfer_price_cents].to_i
          ) unless manual_override
          row.update(attrs)
          counts[:updated] += 1
        else
          create({
            tld:,
            enabled: true,
            registration_price_cents: item[:registration_price_cents].to_i,
            renewal_price_cents: item[:renewal_price_cents].to_i,
            transfer_price_cents: item[:transfer_price_cents].to_i,
            markup_percent: Config.domain_registration_markup_percent.to_f,
            intro_discount_percent: Config.domain_registration_discount_percent.to_f,
            created_at: now
          }.merge(attrs))
          counts[:created] += 1
        end
      end
    end

    counts
  end

  def self.upsert_from_admin(params)
    tld = normalize_tld(params.fetch(:tld))
    attrs = {
      enabled: params.fetch(:enabled, true),
      provider: params.fetch(:provider, "namesilo"),
      registration_price_cents: params.fetch(:registration_price_cents).to_i,
      renewal_price_cents: params.fetch(:renewal_price_cents).to_i,
      transfer_price_cents: params.fetch(:transfer_price_cents).to_i,
      base_registration_price_cents: params.fetch(:base_registration_price_cents, 0).to_i,
      base_renewal_price_cents: params.fetch(:base_renewal_price_cents, 0).to_i,
      base_transfer_price_cents: params.fetch(:base_transfer_price_cents, 0).to_i,
      markup_percent: params.fetch(:markup_percent, 0).to_f,
      intro_discount_percent: params.fetch(:intro_discount_percent, 0).to_f,
      provider_payload: {"source" => "admin", "manual_override" => true},
      updated_at: Time.now
    }

    DB[:domain_tld]
      .insert_conflict(target: :tld, update: attrs)
      .insert({id: generate_uuid, tld:, created_at: Time.now}.merge(attrs))
    first(tld:)
  end

  def price_label(column)
    "$#{format("%0.2f", self[column].to_i / 100.0)}"
  end

  def validate
    super
    validates_includes(PROVIDERS, :provider)
    errors.add(:tld, "must be a valid TLD") unless self.class.valid_tld_name?(tld)
    %i[registration_price_cents renewal_price_cents transfer_price_cents base_registration_price_cents base_renewal_price_cents base_transfer_price_cents].each do |column|
      errors.add(column, "must be zero or greater") if self[column].nil? || self[column].negative?
    end
  end
end

# Table: domain_tld
# Columns:
#  id                            | uuid                     | PRIMARY KEY
#  tld                           | text                     | NOT NULL
#  enabled                       | boolean                  | NOT NULL DEFAULT true
#  provider                      | text                     | NOT NULL DEFAULT 'namesilo'::text
#  registration_price_cents      | integer                  | NOT NULL DEFAULT 0
#  renewal_price_cents           | integer                  | NOT NULL DEFAULT 0
#  transfer_price_cents          | integer                  | NOT NULL DEFAULT 0
#  base_registration_price_cents | integer                  | NOT NULL DEFAULT 0
#  base_renewal_price_cents      | integer                  | NOT NULL DEFAULT 0
#  base_transfer_price_cents     | integer                  | NOT NULL DEFAULT 0
#  markup_percent                | double precision         | NOT NULL DEFAULT 0.0
#  intro_discount_percent        | double precision         | NOT NULL DEFAULT 0.0
#  provider_payload              | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  created_at                    | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at                    | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  domain_tld_pkey              | PRIMARY KEY btree (id)
#  domain_tld_tld_index         | UNIQUE btree (tld)
#  domain_tld_enabled_tld_index | btree (enabled, tld)
# Check constraints:
#  valid_domain_tld_name     | (tld ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'::text)
#  valid_domain_tld_prices   | (registration_price_cents >= 0 AND renewal_price_cents >= 0 AND transfer_price_cents >= 0 AND base_registration_price_cents >= 0 AND base_renewal_price_cents >= 0 AND base_transfer_price_cents >= 0 AND markup_percent >= 0::double precision AND intro_discount_percent >= 0::double precision AND intro_discount_percent <= 100::double precision)
#  valid_domain_tld_provider | (provider = ANY (ARRAY['namesilo'::text, 'domainnameapi'::text, 'centralnic'::text, 'openprovider'::text]))
