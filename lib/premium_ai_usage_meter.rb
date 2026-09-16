# frozen_string_literal: true

# Inference is billed for every provider. Usage is persisted locally and the
# usage-invoice worker collects it; request handling never emits a second,
# provider-specific billing event.
class PremiumAiUsageMeter
  def self.billable_model?(model)
    return false if model.tags.key?("billing_status") && model.tags["billing_status"] != "ready"

    resources = [model.prompt_billing_resource]
    resources << model.completion_billing_resource unless model.tags["capability"] == "Embeddings"
    resources << model.cached_prompt_billing_resource if model.respond_to?(:cached_prompt_billing_resource) && !model.cached_prompt_billing_resource.nil?
    resources.all? { billable_rate(it) }
  end

  def self.billable_rate(resource_family)
    return unless resource_family.is_a?(String) && !resource_family.empty?

    rate = BillingRate.from_resource_properties("InferenceTokens", resource_family, "global")
    rate if rate && rate["unit_price"].to_f.positive?
  end

  def self.validate_rate!(resource_family)
    billable_rate(resource_family) || fail(CloverError.new(
      503, "ModelPricingUnavailable", "This model is unavailable until its usage pricing is configured.",
    ))
  end

  def self.validate_access!(project:, model:)
    if InferenceUsageBilling.payment_required?(project)
      fail CloverError.new(402, "InferencePaymentPending", "AI inference is paused until your usage invoice is paid. Open billing to continue.")
    end

    unless project.has_valid_inference_payment_method?
      fail CloverError.new(402, "BillingRequired", "AI inference requires a valid saved payment method before use.")
    end

    unless billable_model?(model)
      fail CloverError.new(503, "ModelPricingUnavailable", "This model is unavailable until its usage pricing is configured.")
    end
  end
end
