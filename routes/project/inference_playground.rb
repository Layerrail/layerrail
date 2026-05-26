# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    unless Config.ai_inference_enabled
      response.status = 501
      response.content_type = :text
      next "AI Inference is not enabled. Set AI_INFERENCE_ENABLED=true after configuring the inference provider."
    end

    r.get web? do
      content_security_policy.add_connect_src "https://*.#{Config.inference_dns_zone}" unless cloudflare_inference_provider?

      DB.ignore_duplicate_queries do
        @inference_models = all_inference_models.select { it.tags["capability"] == "Text Generation" }
      end

      @inference_api_keys = inference_api_key_ds.all
      @remaining_free_quota = FreeQuota.remaining_free_quota("inference-tokens", @project.id)
      @free_quota_unit = "inference tokens"
      @has_valid_payment_method = @project.has_valid_payment_method?
      view "inference/endpoint/playground"
    end
  end
end
