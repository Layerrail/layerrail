# frozen_string_literal: true

class CloudflareInferenceModel
  attr_reader :model_name, :tags, :prompt_billing_resource, :completion_billing_resource

  def initialize(config)
    @id = config.fetch("id")
    @model_name = config.fetch("model_name")
    @provider = config.fetch("provider", "cloudflare")
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
    @provider
  end

  def load_balancer
    @load_balancer ||= Endpoint.new(@provider)
  end

  class Endpoint
    def initialize(provider)
      @provider = provider
    end

    def health_check_url(path: nil)
      base_url = "#{Config.base_url.chomp("/")}/ai"
      path ? "#{base_url}#{path.start_with?("/") ? path : "/#{path}"}" : base_url
    end
  end

  private

  def provider_label
    case @provider
    when "azure_foundry"
      "Azure AI Foundry"
    when "openrouter"
      "OpenRouter"
    else
      model_name.start_with?("@cf/") ? "Cloudflare Workers AI" : "Cloudflare AI"
    end
  end
end
