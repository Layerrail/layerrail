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
