# frozen_string_literal: true

require_relative "../../model"

class AiAgentEvent < Sequel::Model(:ai_agent_event)
  STATUSES = %w[ok error].freeze

  many_to_one :agent, class: :AiAgent, read_only: true
  many_to_one :api_key, read_only: true

  plugin ResourceMethods
  dataset_module Pagination

  def validate
    super
    validates_includes(STATUSES, :status)
  end
end
