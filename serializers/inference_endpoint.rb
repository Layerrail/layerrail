# frozen_string_literal: true

class Serializers::InferenceEndpoint < Serializers::Base
  def self.serialize_internal(ie, options = {})
    {
      id: ie.ubid,
      name: ie.model_name,
      display_name: ie.tags["display_name"] || ie.model_name,
      url: ie.load_balancer.health_check_url,
      model_name: ie.model_name,
      tags: ie.tags.slice(
        "api",
        "capability",
        "context_length",
        "deprecated",
        "display_name",
        "hf_model",
        "multimodal",
        "provider",
        "source",
      ),
      price: {
        per_million_prompt_tokens: BillingRate.million_token_price(ie.prompt_billing_resource),
        per_million_completion_tokens: BillingRate.million_token_price(ie.completion_billing_resource),
      },
    }
  end
end
