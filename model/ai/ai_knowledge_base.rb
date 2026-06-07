# frozen_string_literal: true

require_relative "../../model"

class AiKnowledgeBase < Sequel::Model(:ai_knowledge_base)
  STATUSES = %w[ready disabled].freeze

  many_to_one :project, read_only: true
  one_to_many :documents, class: :AiKnowledgeDocument, key: :knowledge_base_id, order: Sequel.desc(:created_at), remover: nil, clearer: nil
  one_to_many :agents, class: :AiAgent, key: :knowledge_base_id, remover: nil, clearer: nil

  plugin :association_dependencies, documents: :destroy
  plugin ResourceMethods
  dataset_module Pagination

  def path
    "/ai-app/knowledge-base/#{ubid}"
  end

  def display_state
    status
  end

  def document_count
    documents_dataset.count
  end

  def chunk_count
    AiKnowledgeChunk.where(document_id: documents_dataset.select(:id)).count
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers and hyphens, and must start and end with a lowercase letter or number")
    validates_max_length(128, :name)
    validates_max_length(500, :description)
  end
end
