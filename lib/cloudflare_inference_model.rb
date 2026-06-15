# frozen_string_literal: true

class CloudflareInferenceModel
  attr_reader :model_name, :tags, :prompt_billing_resource, :completion_billing_resource

  def initialize(config)
    @id = config.fetch("id")
    @model_name = config.fetch("model_name")
    provider_label = model_name.start_with?("@cf/") ? "Cloudflare Workers AI" : "Cloudflare AI"
    @tags = config.fetch("tags", {}).merge("provider" => provider_label)
    @prompt_billing_resource = config.fetch("prompt_billing_resource", "preview-input")
    @completion_billing_resource = config.fetch("completion_billing_resource", "preview-output")
  end

  def ubid
    @id
  end

  def name
    model_name
  end

  def provider
    "cloudflare"
  end

  def load_balancer
    @load_balancer ||= Endpoint.new
  end

  class Endpoint
    def health_check_url(path: nil)
      base_url = "#{Config.base_url.chomp("/")}/ai"
      path ? "#{base_url}#{path.start_with?("/") ? path : "/#{path}"}" : base_url
    end
  end
end
