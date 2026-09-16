# frozen_string_literal: true

require_relative "../model"

class PremiumAiTrial < Sequel::Model
  many_to_one :project

  ELIGIBLE_MODELS = %w[
    gpt-5.5
    gpt-5.6-luna
    gpt-5.6-sol
    gpt-5.6-terra
    claude-fable-5
    claude-sonnet-5
  ].freeze

  def self.active_for?(_project, _model, **_)
    # Retain historical trial records for old invoices. New requests are paid,
    # including requests from projects whose previous trial has not expired.
    false
  end
end
