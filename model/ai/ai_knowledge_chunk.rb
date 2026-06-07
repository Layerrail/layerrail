# frozen_string_literal: true

require_relative "../../model"

class AiKnowledgeChunk < Sequel::Model(:ai_knowledge_chunk)
  many_to_one :document, class: :AiKnowledgeDocument, read_only: true

  plugin ResourceMethods

  def validate
    super
    errors.add(:ordinal, "must be greater than or equal to 0") if ordinal && ordinal.negative?
    errors.add(:content, "cannot be empty") if content.to_s.strip.empty?
  end
end
