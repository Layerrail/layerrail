# frozen_string_literal: true

require_relative "../../model"

class AiKnowledgeDocument < Sequel::Model(:ai_knowledge_document)
  SOURCE_TYPES = %w[text url api].freeze
  STATUSES = %w[ready disabled].freeze
  CHUNK_SIZE = 1800
  CHUNK_OVERLAP = 240

  many_to_one :knowledge_base, class: :AiKnowledgeBase, read_only: true
  one_to_many :chunks, class: :AiKnowledgeChunk, key: :document_id, order: :ordinal, remover: nil, clearer: nil

  plugin :association_dependencies, chunks: :destroy
  plugin ResourceMethods

  def path
    "#{knowledge_base.path}/document/#{ubid}"
  end

  def refresh_chunks!
    DB.transaction do
      chunks_dataset.destroy
      chunk_text(content).each_with_index do |chunk_content, ordinal|
        AiKnowledgeChunk.create(
          document_id: id,
          ordinal:,
          content: chunk_content,
          token_count: [(chunk_content.length / 4.0).ceil, 1].max,
        )
      end
    end
  end

  def validate
    super
    validates_includes(SOURCE_TYPES, :source_type)
    validates_includes(STATUSES, :status)
    validates_max_length(160, :title)
    validates_max_length(128_000, :content)
    errors.add(:content, "cannot be empty") if content.to_s.strip.empty?
  end

  private

  def chunk_text(text)
    normalized = text.to_s.gsub(/\r\n?/, "\n").strip
    return [] if normalized.empty?

    chunks = []
    cursor = 0
    while cursor < normalized.length
      slice = normalized[cursor, CHUNK_SIZE]
      break unless slice

      chunks << slice.strip
      cursor += CHUNK_SIZE - CHUNK_OVERLAP
    end
    chunks.reject(&:empty?)
  end
end
