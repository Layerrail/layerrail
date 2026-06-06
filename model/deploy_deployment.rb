# frozen_string_literal: true

require_relative "../model"

class DeployDeployment < Sequel::Model(:deploy_deployment)
  STATUSES = %w[queued provisioning building live failed canceled].freeze
  TRIGGERS = %w[manual].freeze

  one_to_one :strand, key: :id
  many_to_one :app, class: :DeployApp, read_only: true

  plugin ResourceMethods
  dataset_module Pagination

  def path
    "#{app.path}/deployment/#{ubid}"
  end

  def log_excerpt
    log.to_s.lines.last(80).join
  end

  def display_state
    status
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_includes(TRIGGERS, :trigger)
  end
end

# Table: deploy_deployment
# Columns:
#  id              | uuid                     | PRIMARY KEY
#  app_id          | uuid                     | NOT NULL
#  status          | text                     | NOT NULL DEFAULT 'queued'::text
#  trigger         | text                     | NOT NULL DEFAULT 'manual'::text
#  commit_sha      | text                     |
#  commit_message  | text                     |
#  log             | text                     |
#  failure_message | text                     |
#  started_at      | timestamp with time zone |
#  finished_at     | timestamp with time zone |
#  created_at      | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at      | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  deploy_deployment_pkey                    | PRIMARY KEY btree (id)
#  deploy_deployment_app_id_created_at_index | btree (app_id, created_at)
#  deploy_deployment_app_id_index            | btree (app_id)
# Check constraints:
#  valid_deploy_deployment_status | (status = ANY (ARRAY['queued'::text, 'provisioning'::text, 'building'::text, 'live'::text, 'failed'::text, 'canceled'::text]))
# Foreign key constraints:
#  deploy_deployment_app_id_fkey | (app_id) REFERENCES deploy_app(id)
