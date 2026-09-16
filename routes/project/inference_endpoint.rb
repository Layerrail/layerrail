# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    unless Config.ai_inference_enabled
      response.status = 501
      response.content_type = :text
      next "AI Inference is not enabled. Set AI_INFERENCE_ENABLED=true after configuring the inference provider."
    end

    r.get api? do
      authorize("Project:view", @project)
      {items: Serializers::InferenceEndpoint.serialize(all_inference_models)}
    end

    r.get web? do
      authorize("Project:view", @project)
      @inference_models = all_inference_models
      @has_valid_payment_method = @project.has_valid_inference_payment_method?
      view "inference/endpoint/index"
    end
  end
end
