# frozen_string_literal: true

class Serializers::InferenceEndpoint < Serializers::Base
  def self.serialize_internal(ie, options = {})
    billable = PremiumAiUsageMeter.billable_model?(ie)
    price_for = ->(resource) { BillingRate.million_token_price(resource) if billable && PremiumAiUsageMeter.billable_rate(resource) }
    {
      id: ie.ubid,
      name: ie.model_name,
      display_name: ie.tags["display_name"] || ie.model_name,
      url: ie.load_balancer.health_check_url,
      model_name: ie.model_name,
      available: billable,
      tags: ie.tags.slice(
        "api",
        "capability",
        "context_length",
        "deprecated",
        "display_name",
        "hf_model",
        "multimodal",
        "pricing",
        "provider",
        "source",
      ),
      price: {
        per_million_prompt_tokens: price_for.call(ie.prompt_billing_resource),
        per_million_completion_tokens: price_for.call(ie.completion_billing_resource),
        per_million_cached_prompt_tokens: ie.respond_to?(:cached_prompt_billing_resource) ? price_for.call(ie.cached_prompt_billing_resource) : nil,
      },
    }
  end
end
