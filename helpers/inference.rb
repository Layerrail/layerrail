# frozen_string_literal: true

class Clover
  CLOUDFLARE_NATIVE_CAPABILITIES = [
    "Automatic Speech Recognition",
    "Image Classification",
    "Image Text to Text",
    "Image-to-Text",
    "Object Detection",
    "Rerank",
    "Summarization",
    "Text Classification",
    "Text-to-Image",
    "Text-to-Speech",
    "Translation",
  ].freeze

  def cloudflare_inference_provider?
    Config.ai_inference_provider == "cloudflare"
  end

  def cloudflare_inference_models
    Option::AI_MODELS
      .select { it["provider"] == "cloudflare" && it.fetch("enabled", true) }
      .map { CloudflareInferenceModel.new(it) }
  end

  def visible_capable_models(dataset)
    dataset
      .where(Sequel.|([:visible],
        Sequel.pg_jsonb_op(:tags)["visible_projects"].contains([@project.id])))
      .where(Sequel.pg_jsonb_op(:tags).get_text("capability") => ["Text Generation", "Embeddings"])
      .order(:model_name)
  end

  def inference_endpoint_ds
    dataset_private = dataset_authorize(@project.inference_endpoints_dataset, "InferenceEndpoint:view")
    dataset_public = InferenceEndpoint.is_public

    dataset = dataset_private.union(dataset_public)
    dataset = visible_capable_models(dataset)
    dataset.eager(:load_balancer)
  end

  def inference_router_model_ds
    visible_capable_models(InferenceRouterModel)
      .eager_graph(inference_router_targets: {inference_router: :load_balancer})
      .exclude(inference_router_model_id: nil)
  end

  def all_inference_models
    return cloudflare_inference_models if cloudflare_inference_provider?

    inference_endpoint_ds.eager(:location, load_balancer: :private_subnet).all +
      inference_router_model_ds.eager(inference_router: {load_balancer: :private_subnet}).all
  end

  def inference_api_key_ds
    dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceApiKey:view")
    dataset = dataset.where(is_valid: true)
    dataset.order(:created_at)
  end

  def handle_cloudflare_ai_request(path, capability)
    no_authorization_needed
    no_audit_log

    unless Config.ai_inference_enabled && cloudflare_inference_provider?
      fail CloverError.new(501, "NotEnabled", "Cloudflare AI Inference is not enabled.")
    end

    api_key = inference_api_key_from_authorization_header
    fail CloverError.new(401, "InvalidCredentials", "invalid inference API key provided in Authorization header") unless api_key
    fail CloverError.new(403, "ProjectInactive", "the project for this inference API key is not active") unless api_key.project&.active?

    payload = parse_inference_payload
    model = cloudflare_inference_models.find { it.model_name == payload["model"] && it.tags["capability"] == capability }
    fail CloverError.new(400, "InvalidRequest", "model is not enabled for #{capability.downcase}") unless model

    normalize_cloudflare_payload!(payload, path)
    payload.delete("stream_options")

    status, body = CloudflareWorkersAiClient.new.openai_request(path, payload)
    response.status = status
    record_cloudflare_inference_usage(api_key, model, body, payload) if status == 200
    body
  end

  def handle_cloudflare_ai_run_request
    no_authorization_needed
    no_audit_log

    unless Config.ai_inference_enabled && cloudflare_inference_provider?
      fail CloverError.new(501, "NotEnabled", "Cloudflare AI Inference is not enabled.")
    end

    api_key = inference_api_key_from_authorization_header
    fail CloverError.new(401, "InvalidCredentials", "invalid inference API key provided in Authorization header") unless api_key
    fail CloverError.new(403, "ProjectInactive", "the project for this inference API key is not active") unless api_key.project&.active?

    payload = parse_inference_payload
    model_name = payload.delete("model")
    fail CloverError.new(400, "InvalidRequest", "model is required") if model_name.to_s.empty?

    model = cloudflare_inference_models.find { it.model_name == model_name }
    fail CloverError.new(400, "InvalidRequest", "model is not enabled") unless model
    unless CLOUDFLARE_NATIVE_CAPABILITIES.include?(model.tags["capability"])
      fail CloverError.new(400, "InvalidRequest", "model is not enabled for the native run route")
    end

    payload.delete("stream")
    status, body = CloudflareWorkersAiClient.new.run_request(model.model_name, payload)
    response.status = status
    record_cloudflare_inference_usage(api_key, model, body, payload) if status == 200
    body
  end

  def inference_api_key_from_authorization_header
    raw_key = env["HTTP_AUTHORIZATION"].to_s.sub(/\ABearer:?\s+/i, "")
    return if raw_key.empty?

    ApiKey.where(used_for: "inference_endpoint", is_valid: true).all.find do |api_key|
      api_key.key.bytesize == raw_key.bytesize && Rack::Utils.secure_compare(api_key.key, raw_key)
    rescue
      false
    end
  end

  def parse_inference_payload
    JSON.parse(request.body.read)
  rescue JSON::ParserError
    fail CloverError.new(400, "InvalidRequest", "request body must be valid JSON")
  end

  def normalize_cloudflare_payload!(payload, path)
    case path
    when "chat/completions"
      messages = payload["messages"]
      fail CloverError.new(400, "InvalidRequest", "messages must be an array") unless messages.is_a?(Array)

      messages.each do |message|
        next unless message["content"].is_a?(Array)

        message["content"] = message["content"].filter_map do |part|
          part["text"] if part.is_a?(Hash) && part["type"] == "text"
        end.join("\n")
      end
      payload["stream"] = false
    when "embeddings"
      payload.delete("stream")
    end
  end

  def record_cloudflare_inference_usage(api_key, model, body, payload)
    result = body["result"].is_a?(Hash) ? body["result"] : {}
    usage = body["usage"] || result["usage"] || {}
    prompt_tokens = usage["prompt_tokens"].to_i
    completion_tokens = usage["completion_tokens"].to_i
    total_tokens = usage["total_tokens"].to_i

    prompt_tokens = estimate_inference_tokens(cloudflare_request_text(body, payload)) if prompt_tokens.zero?
    completion_tokens = [total_tokens - prompt_tokens, 0].max if completion_tokens.zero? && total_tokens.positive?
    completion_tokens = estimate_inference_tokens(cloudflare_response_text(body)) if completion_tokens.zero? && !["Embeddings", "Text-to-Image", "Text-to-Speech"].include?(model.tags["capability"])

    record_inference_tokens(api_key, model.prompt_billing_resource, prompt_tokens)
    record_inference_tokens(api_key, model.completion_billing_resource, completion_tokens)
  end

  def record_inference_tokens(api_key, resource_family, tokens)
    return unless tokens.positive?

    rate = BillingRate.from_resource_properties("InferenceTokens", resource_family, "global")
    return unless rate

    begin_time = Time.now.to_date.to_time
    end_time = begin_time + 24 * 60 * 60
    today_record = BillingRecord
      .where(project_id: api_key.project_id, resource_id: api_key.id, billing_rate_id: rate["id"])
      .where { Sequel.pg_range(it.span).overlaps(Sequel.pg_range(begin_time...end_time)) }
      .first

    if today_record
      today_record.amount = Sequel[:amount] + tokens
      today_record.save_changes(validate: false)
    else
      BillingRecord.create(
        project_id: api_key.project_id,
        resource_id: api_key.id,
        resource_name: "#{resource_family} #{begin_time.strftime("%Y-%m-%d")}",
        billing_rate_id: rate["id"],
        span: Sequel.pg_range(begin_time...end_time),
        amount: tokens,
        resource_tags: {provider: "cloudflare"},
      )
    end
  rescue Sequel::Error => ex
    Clog.emit("Failed to update Cloudflare inference billing record", Util.exception_to_hash(ex, into: {project_id: api_key.project_id, resource_family:, tokens:}))
  end

  def estimate_inference_tokens(value)
    text = case value
    when Array
      value.map { estimate_inference_text(it) }.join("\n")
    else
      estimate_inference_text(value)
    end
    [(text.length / 4.0).ceil, 1].max
  end

  def estimate_inference_text(value)
    case value
    when Hash
      if value.key?("content")
        estimate_inference_text(value["content"])
      elsif value.key?("text")
        value["text"].to_s
      elsif value.key?("input")
        estimate_inference_text(value["input"])
      else
        value.values.map { estimate_inference_text(it) }.join("\n")
      end
    when Array
      return "" if value.all? { it.is_a?(Numeric) }

      value.map { estimate_inference_text(it) }.join("\n")
    else
      value.to_s
    end
  end

  def cloudflare_request_text(_body, payload)
    [
      payload["messages"],
      payload["input"],
      payload["prompt"],
      payload["text"],
      payload["input_text"],
      payload["query"],
      payload["contexts"],
    ].compact
  end

  def cloudflare_response_text(body)
    result = body["result"].is_a?(Hash) ? body["result"] : {}
    [
      body.dig("choices", 0, "message", "content"),
      body.dig("choices", 0, "text"),
      result["response"],
      result["text"],
      result["translated_text"],
      result["summary"],
      result["description"],
      *Array(body["result"]).map { it.is_a?(Hash) ? [it["label"], it["score"]].compact.join(" ") : nil },
    ].compact.join("\n")
  end
end
