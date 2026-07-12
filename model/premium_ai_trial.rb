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

  def self.active_for?(project, model, now: Time.now)
    return false unless Config.premium_ai_trial_enabled
    return false unless ELIGIBLE_MODELS.include?(model.model_name)

    trial_for(project, now:).ends_at > now
  end

  def self.trial_for(project, now: Time.now)
    where(project_id: project.id).first || create(
      project_id: project.id,
      started_at: now,
      ends_at: now + Config.premium_ai_trial_days.to_i * 24 * 60 * 60,
    )
  rescue Sequel::UniqueConstraintViolation
    where(project_id: project.id).first || raise
  end
end
