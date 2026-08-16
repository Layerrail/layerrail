# frozen_string_literal: true

class CloudflareInferenceModel
  attr_reader :model_name, :tags, :prompt_billing_resource, :completion_billing_resource

  def initialize(config)
    @model_name = config.fetch("model_name")
    @provider = config.fetch("provider", "cloudflare")
    @id = config["id"].to_s.strip
    if @id.empty?
      @id = fallback_id
      Clog.emit("AI model config missing id; using fallback id", {
        ai_model_config_missing_id: {
          model_name: @model_name,
          provider: @provider,
          fallback_id: @id,
        }
      }) if defined?(Clog)
    end
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
      base_url = if Config.api_url
        Config.api_url.chomp("/")
      else
        "#{Config.base_url.chomp("/")}/ai"
      end
      path ? "#{base_url}#{path.start_with?("/") ? path : "/#{path}"}" : base_url
    end
  end

  private

  def fallback_id
    "#{@provider}-#{@model_name}".downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  end

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
