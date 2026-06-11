# frozen_string_literal: true

require_relative "../model"

class DomainBundle < Sequel::Model(:domain_bundle)
  TYPES = %w[startup saas game_server ai_app custom].freeze
  STATUSES = %w[draft active archived].freeze
  SLUG_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  many_to_one :project, read_only: true
  many_to_one :domain_registration, read_only: true
  many_to_one :deploy_app, read_only: true

  plugin ResourceMethods

  def self.slugify(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")[0, 63]
  end

  def path
    "/domain/bundle/#{ubid}"
  end

  def display_type
    bundle_type.tr("_", " ")
  end

  def display_state
    status.tr("_", " ")
  end

  def validate
    super
    validates_includes(TYPES, :bundle_type)
    validates_includes(STATUSES, :status)
    errors.add(:slug, "must be a URL-safe slug") unless SLUG_PATTERN.match?(slug.to_s)
    validates_presence %i[name slug]
  end
end

# Table: domain_bundle
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  project_id             | uuid                     | NOT NULL
#  domain_registration_id | uuid                     |
#  deploy_app_id          | uuid                     |
#  name                   | text                     | NOT NULL
#  slug                   | text                     | NOT NULL
#  bundle_type            | text                     | NOT NULL DEFAULT 'startup'::text
#  status                 | text                     | NOT NULL DEFAULT 'draft'::text
#  description            | text                     |
#  settings               | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  created_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
