# frozen_string_literal: true

require_relative "../../model"

class AiAgent < Sequel::Model(:ai_agent)
  STATUSES = %w[active disabled].freeze
  DEFAULT_MODEL = "@cf/meta/llama-3.2-3b-instruct"

  many_to_one :project, read_only: true
  many_to_one :knowledge_base, class: :AiKnowledgeBase, read_only: true
  one_to_many :events, class: :AiAgentEvent, key: :agent_id, order: Sequel.desc(:created_at), remover: nil, clearer: nil

  plugin :association_dependencies, events: :destroy
  plugin ResourceMethods
  dataset_module Pagination

  def path
    "/ai-app/#{ubid}"
  end

  def endpoint_path
    "/ai/v1/agents/#{ubid}/messages"
  end

  def public_url
    if Config.api_url
      "#{Config.api_url.chomp("/")}/v1/agents/#{ubid}/messages"
    else
      "#{Config.base_url.chomp("/")}#{endpoint_path}"
    end
  end

  def active?
    status == "active"
  end

  def display_state
    status
  end

  def before_validation
    self.public_slug = self.class.slugify(name) if public_slug.to_s.empty? && name
    self.model_name = DEFAULT_MODEL if model_name.to_s.empty?
    self.template = "custom" if template.to_s.empty?
    self.status = "active" if status.to_s.empty?
    self.tools = [] unless tools.is_a?(Array)
    super
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers and hyphens, and must start and end with a lowercase letter or number")
    validates_format(Validation::ALLOWED_NAME_PATTERN, :public_slug, message: "must only contain lowercase letters, numbers and hyphens, and must start and end with a lowercase letter or number")
    validates_max_length(128, :name)
    validates_max_length(64, :public_slug)
    validates_max_length(500, :description)
    validates_max_length(12_000, :system_prompt)
  end

  def retrieval_context(query, limit: 4)
    return [] unless knowledge_base

    terms = query.to_s.downcase.scan(/[a-z0-9]{3,}/).uniq
    AiKnowledgeChunk
      .where(document_id: knowledge_base.documents_dataset.where(status: "ready").select(:id))
      .all
      .map { |chunk| [chunk, context_score(chunk.content, terms)] }
      .select { |_, score| score.positive? }
      .sort_by { |_, score| -score }
      .first(limit)
      .map(&:first)
  end

  def self.slugify(value)
    slug = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 63]
    slug.empty? ? "agent" : slug
  end

  private

  def context_score(content, terms)
    text = content.to_s.downcase
    terms.sum { |term| text.scan(term).length }
  end
end
