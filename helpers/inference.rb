# frozen_string_literal: true

require "securerandom"

class Clover
  AI_APP_TEMPLATES = [
    {
      id: "support-assistant",
      name: "Support assistant",
      description: "Answers product questions from your docs and support notes.",
      prompt: "You are a concise support assistant. Answer from the provided context first. If the context is missing, say what you need next.",
      tools: ["knowledge_search"],
    },
    {
      id: "docs-search",
      name: "Docs search",
      description: "Turns technical documentation into API-ready answers.",
      prompt: "You are a developer documentation assistant. Prefer exact commands, links, and short examples when the context supports them.",
      tools: ["knowledge_search"],
    },
    {
      id: "sales-engineer",
      name: "Sales engineer",
      description: "Explains product fit, tradeoffs, and implementation paths.",
      prompt: "You are a technical sales engineer. Give practical guidance, avoid hype, and make infrastructure tradeoffs clear.",
      tools: ["knowledge_search"],
    },
    {
      id: "game-server-helper",
      name: "Game server helper",
      description: "Helps customers choose server sizes and troubleshoot hosting basics.",
      prompt: "You are a game server infrastructure assistant. Keep answers practical, performance-aware, and easy to act on.",
      tools: ["knowledge_search"],
    },
  ].freeze

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
    "Voice Activity Detection",
  ].freeze

  def catalog_inference_provider?
    ai_inference_providers.any? { |provider| %w[cloudflare azure_foundry openrouter].include?(provider) }
  end

  def ai_inference_providers
    Config.ai_inference_provider.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def cloudflare_inference_models
    Option::AI_MODELS
      .select { it["provider"] == "cloudflare" && it.fetch("enabled", true) }
      .map { CloudflareInferenceModel.new(it) }
  end

  def azure_foundry_inference_models
    Option::AI_MODELS
      .select { it["provider"] == "azure_foundry" && it.fetch("enabled", true) }
      .map { CloudflareInferenceModel.new(it) }
  end

  def catalog_inference_models
    Option::AI_MODELS
      .select { |it| ai_inference_providers.include?(it["provider"]) && it.fetch("enabled", true) }
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
    return catalog_inference_models if catalog_inference_provider?

    inference_endpoint_ds.eager(:location, load_balancer: :private_subnet).all +
      inference_router_model_ds.eager(inference_router: {load_balancer: :private_subnet}).all
  end

  def inference_models_for_project(project)
    return catalog_inference_models if catalog_inference_provider?

    previous_project = @project
    @project = project
    all_inference_models
  ensure
    @project = previous_project
  end

  def handle_inference_models_request
    no_authorization_needed
    no_audit_log

    unless Config.ai_inference_enabled && catalog_inference_provider?
      fail CloverError.new(501, "NotEnabled", "AI Inference is not enabled.")
    end

    api_key = inference_api_key_from_authorization_header
    fail CloverError.new(401, "InvalidCredentials", "invalid inference API key provided in Authorization header") unless api_key
    fail CloverError.new(403, "ProjectInactive", "the project for this inference API key is not active") unless api_key.project&.active?

    {
      "object" => "list",
      "data" => inference_models_for_project(api_key.project).map { openai_model_entry(it) },
    }
  end

  def inference_api_key_ds
    dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceApiKey:view")
    dataset = dataset.where(is_valid: true)
    dataset.order(:created_at)
  end

  def ai_agent_ds
    dataset_authorize(@project.ai_agents_dataset.reverse(:created_at), "Project:view")
  end

  def ai_knowledge_base_ds
    dataset_authorize(@project.ai_knowledge_bases_dataset.reverse(:created_at), "Project:view")
  end

  def handle_cloudflare_ai_request(path, capability)
    no_authorization_needed
    no_audit_log

    unless Config.ai_inference_enabled && catalog_inference_provider?
      fail CloverError.new(501, "NotEnabled", "AI Inference is not enabled.")
    end

    api_key = inference_api_key_from_authorization_header
    fail CloverError.new(401, "InvalidCredentials", "invalid inference API key provided in Authorization header") unless api_key
    fail CloverError.new(403, "ProjectInactive", "the project for this inference API key is not active") unless api_key.project&.active?

    payload = parse_inference_payload
    model = catalog_inference_models.find { it.model_name == payload["model"] && it.tags["capability"] == capability }
    fail CloverError.new(400, "InvalidRequest", "model is not enabled for #{capability.downcase}") unless model
    validate_premium_ai_access!(api_key, model)
    return handle_azure_foundry_ai_request(path, capability, api_key, model, payload) if model.provider == "azure_foundry"

    if capability == "Text Generation" && cloudflare_text_model_path(model) != path
      fail CloverError.new(400, "InvalidRequest", "model uses /v1/#{cloudflare_text_model_path(model)}")
    end

    normalize_cloudflare_payload!(payload, path)
    compact_cloudflare_payload!(payload)

    if path == "chat/completions" && payload["stream"]
      stream_cloudflare_ai_request(api_key, model, payload)
    end

    payload.delete("stream_options")

    status, body = CloudflareWorkersAiClient.new.openai_request(path, payload)
    response.status = status
    record_cloudflare_inference_usage(api_key, model, body, payload) if status == 200
    body
  end

  def handle_azure_foundry_ai_request(path, capability, api_key, model, payload)
    # Translate Responses API to Chat Completions for Azure Foundry compatibility
    if path == "responses" && capability == "Text Generation"
      return handle_azure_foundry_responses_request(api_key, model, payload)
    end

    fail CloverError.new(400, "InvalidRequest", "Azure AI Foundry currently supports this model through /v1/chat/completions") unless path == "chat/completions" && capability == "Text Generation"

    normalize_cloudflare_payload!(payload, path)
    normalize_azure_foundry_payload!(payload, model)
    compact_cloudflare_payload!(payload)
    deployment = model.tags["deployment"] || model.model_name
    payload["model"] = deployment

    # Azure AI Foundry does not support streaming responses.
    payload.delete("stream")
    payload.delete("stream_options")
    status, body, served_model = azure_foundry_chat_completion_with_fallback(model, deployment, payload)
    response.status = status
    response["X-LayerRail-AI-Model"] = served_model.model_name
    response["X-LayerRail-AI-Fallback-Model"] = served_model.model_name if served_model.model_name != model.model_name
    record_cloudflare_inference_usage(api_key, served_model, body, payload) if status == 200
    body
  end

  def handle_azure_foundry_responses_request(api_key, model, payload)
    # Translate Responses API format to Chat Completions format
    chat_payload = translate_responses_to_chat_completions(payload, model)
    
    # Call Azure Foundry with Chat Completions format
    normalize_cloudflare_payload!(chat_payload, "chat/completions")
    normalize_azure_foundry_payload!(chat_payload, model)
    compact_cloudflare_payload!(chat_payload)
    deployment = model.tags["deployment"] || model.model_name
    chat_payload["model"] = deployment
    chat_payload.delete("stream")
    chat_payload.delete("stream_options")
    
    status, body, served_model = azure_foundry_chat_completion_with_fallback(model, deployment, chat_payload)
    response.status = status
    response["X-LayerRail-AI-Model"] = served_model.model_name
    response["X-LayerRail-AI-Fallback-Model"] = served_model.model_name if served_model.model_name != model.model_name
    record_cloudflare_inference_usage(api_key, served_model, body, chat_payload) if status == 200
    
    # Translate Chat Completions response back to Responses API format
    translate_chat_completions_to_responses(body, payload)
  end

  def translate_responses_to_chat_completions(payload, model)
    chat_payload = payload.dup
    
    # Convert Responses API input/messages to Chat Completions messages format
    if chat_payload["input"].is_a?(Array)
      messages = []
      
      # Add system instructions as system message
      if chat_payload["instructions"]
        messages << {"role" => "system", "content" => chat_payload["instructions"]}
      end
      
      # Convert input array to messages
      chat_payload["input"].each do |item|
        next unless item.is_a?(Hash)
        
        role = item["role"] || "user"
        content = item["content"] || ""
        messages << {"role" => role, "content" => content}
      end
      
      chat_payload["messages"] = messages
    elsif chat_payload["input"].is_a?(String)
      # Single string input becomes user message
      messages = []
      if chat_payload["instructions"]
        messages << {"role" => "system", "content" => chat_payload["instructions"]}
      end
      messages << {"role" => "user", "content" => chat_payload["input"]}
      chat_payload["messages"] = messages
    end
    
    # Map Responses API parameters to Chat Completions
    chat_payload["max_tokens"] ||= chat_payload.delete("max_output_tokens")
    chat_payload.delete("input")
    chat_payload.delete("instructions")
    chat_payload.delete("response_format")
    
    chat_payload
  end

  def translate_chat_completions_to_responses(body, original_payload)
    return body if body["error"]
    
    # Extract content from Chat Completions response
    content = ""
    if body["choices"] && body["choices"].first
      choice = body["choices"].first
      if choice["message"]
        content = choice["message"]["content"] || ""
      elsif choice["delta"]
        content = choice["delta"]["content"] || ""
      end
    end
    
    # Build Responses API format response
    responses_response = {
      "id" => body["id"] || "resp_#{SecureRandom.hex(16)}",
      "status" => "succeeded",
      "output" => [
        {
          "content" => [
            {"type" => "text", "text" => content}
          ],
          "role" => "assistant"
        }
      ],
      "created" => body["created"] || Time.now.to_i,
      "model" => body["model"] || original_payload["model"],
      "usage" => {
        "input_tokens" => body.dig("usage", "prompt_tokens") || 0,
        "output_tokens" => body.dig("usage", "completion_tokens") || 0,
        "total_tokens" => body.dig("usage", "total_tokens") || 0
      }
    }
    
    responses_response
  end

  def azure_foundry_chat_completion_with_fallback(model, deployment, payload)
    client = AzureFoundryClient.new
    status, body = azure_foundry_chat_completion_request(client, model, deployment, payload)
    return [status, body, model] unless azure_foundry_rate_limited?(status, body)

    Clog.emit("Azure AI Foundry model is rate limited", {
      azure_foundry_model_rate_limited: {
        model: model.model_name,
        deployment:,
        provider: model.provider,
        error: azure_foundry_error_message(body)
      }
    })

    fallback_models = azure_foundry_rate_limit_fallback_models(model)
    fallback_models.each do |fallback_model|
      fallback_deployment = fallback_model.tags["deployment"] || fallback_model.model_name
      fallback_payload = JSON.parse(JSON.generate(payload))
      normalize_azure_foundry_payload!(fallback_payload, fallback_model)
      fallback_payload["model"] = fallback_deployment
      status, body = azure_foundry_chat_completion_request(client, fallback_model, fallback_deployment, fallback_payload)
      return [status, body, fallback_model] unless azure_foundry_rate_limited?(status, body)

      Clog.emit("Azure AI Foundry fallback model is rate limited", {
        azure_foundry_fallback_model_rate_limited: {
          model: fallback_model.model_name,
          deployment: fallback_deployment,
          error: azure_foundry_error_message(body)
        }
      })
    end

    [429, {
      "error" => {
        "code" => "PremiumAIRateLimited",
        "message" => "Premium AI capacity is temporarily rate limited. Please retry shortly or choose another premium model.",
        "model" => model.model_name,
        "provider" => "azure_foundry"
      }
    }, model]
  end

  def azure_foundry_chat_completion_request(client, model, deployment, payload)
    return client.anthropic_messages(deployment, payload) if azure_foundry_anthropic_model?(model)

    client.chat_completion(deployment, payload)
  end

  def azure_foundry_anthropic_model?(model)
    model.model_name.to_s.start_with?("claude-") || model.tags["api"] == "anthropic"
  end

  def azure_foundry_rate_limit_fallback_models(model)
    return [] unless Config.premium_ai_rate_limit_fallback_enabled

    catalog_inference_models
      .select { it.provider == "azure_foundry" && it.tags["capability"] == model.tags["capability"] && it.model_name != model.model_name }
      .sort_by { |candidate|
        [
          candidate.tags["reasoning"] ? 1 : 0,
          candidate.tags["pricing"]&.[]("output").to_f,
          candidate.tags["pricing"]&.[]("input").to_f,
          candidate.model_name
        ]
      }
  end

  def azure_foundry_rate_limited?(status, body)
    return true if status.to_i == 429

    error_message = azure_foundry_error_message(body).downcase
    error_message.include?("rate limit") || error_message.include?("too many requests")
  end

  def azure_foundry_error_message(body)
    [
      body.dig("error", "message"),
      body.dig("error", "code"),
      body["message"],
      body.to_json
    ].compact.first.to_s
  end

  def normalize_azure_foundry_payload!(payload, model)
    deployment = (model.tags["deployment"] || model.model_name).to_s
    if deployment.start_with?("gpt-5") || deployment.start_with?("o")
      payload["max_completion_tokens"] ||= payload.delete("max_tokens")
      payload.delete("max_tokens")
    end
    payload.delete("model")
  end

  def handle_cloudflare_ai_run_request
    no_authorization_needed
    no_audit_log

    unless Config.ai_inference_enabled && catalog_inference_provider?
      fail CloverError.new(501, "NotEnabled", "AI Inference is not enabled.")
    end

    api_key = inference_api_key_from_authorization_header
    fail CloverError.new(401, "InvalidCredentials", "invalid inference API key provided in Authorization header") unless api_key
    fail CloverError.new(403, "ProjectInactive", "the project for this inference API key is not active") unless api_key.project&.active?

    payload = parse_inference_payload
    model_name = payload.delete("model")
    fail CloverError.new(400, "InvalidRequest", "model is required") if model_name.to_s.empty?

    model = cloudflare_inference_models.find { it.model_name == model_name }
    fail CloverError.new(400, "InvalidRequest", "model is not enabled") unless model
    validate_premium_ai_access!(api_key, model)
    unless CLOUDFLARE_NATIVE_CAPABILITIES.include?(model.tags["capability"]) || cloudflare_text_model_path(model) == "run"
      fail CloverError.new(400, "InvalidRequest", "model is not enabled for the native run route")
    end

    payload.delete("stream")
    if model.tags["capability"] == "Text-to-Speech" && model.model_name.start_with?("@cf/deepgram/") && payload["text"].to_s.empty?
      payload["text"] = payload.delete("prompt")
    end
    compact_cloudflare_payload!(payload)
    status, body = cloudflare_run_request(CloudflareWorkersAiClient.new, model, payload)
    response.status = status
    record_cloudflare_inference_usage(api_key, model, body, payload) if status == 200
    body
  end

  def handle_ai_agent_message_request(agent_ref)
    no_authorization_needed
    no_audit_log

    unless Config.ai_inference_enabled && catalog_inference_provider?
      fail CloverError.new(501, "NotEnabled", "Cloudflare AI Models are not enabled.")
    end

    api_key = inference_api_key_from_authorization_header
    fail CloverError.new(401, "InvalidCredentials", "invalid inference API key provided in Authorization header") unless api_key
    fail CloverError.new(403, "ProjectInactive", "the project for this inference API key is not active") unless api_key.project&.active?

    agent = ai_agent_from_ref(api_key.project, agent_ref)
    fail CloverError.new(404, "NotFound", "AI agent not found") unless agent
    fail CloverError.new(403, "AgentDisabled", "AI agent is disabled") unless agent.active?

    payload = parse_inference_payload
    messages = ai_agent_messages(payload)
    fail CloverError.new(400, "InvalidRequest", "message or messages is required") if messages.empty?

    model = cloudflare_inference_models.find { it.model_name == agent.model_name && it.tags["capability"] == "Text Generation" }
    fail CloverError.new(400, "InvalidRequest", "agent model is not enabled for text generation") unless model
    validate_premium_ai_access!(api_key, model)

    user_query = ai_agent_user_query(messages)
    context_chunks = agent.retrieval_context(user_query)
    request_payload = ai_agent_cloudflare_payload(agent, model, messages, context_chunks, payload)
    compact_cloudflare_payload!(request_payload)
    request_path = cloudflare_text_model_path(model)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client = CloudflareWorkersAiClient.new
    status, body = if request_path == "run"
      cloudflare_run_request(client, model, request_payload)
    else
      client.openai_request(request_path, request_payload)
    end
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    response.status = status

    if status == 200
      record_cloudflare_inference_usage(api_key, model, body, request_payload)
      record_ai_agent_event(agent, api_key, model, body, request_payload, latency_ms:, status: "ok")
    else
      record_ai_agent_event(agent, api_key, model, body, request_payload, latency_ms:, status: "error")
    end

    {
      agent: {
        id: agent.ubid,
        name: agent.name,
        model: agent.model_name,
      },
      context: context_chunks.map { |chunk|
        {
          document_id: chunk.document.ubid,
          title: chunk.document.title,
          content: chunk.content,
        }
      },
      output: ai_agent_response_text(body),
      response: body,
    }
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

  def ai_agent_from_ref(project, agent_ref)
    if (uuid = UBID.to_uuid(agent_ref.to_s))
      project.ai_agents_dataset.first(id: uuid)
    else
      project.ai_agents_dataset.first(public_slug: agent_ref.to_s)
    end
  end

  def ai_agent_messages(payload)
    if payload["messages"].is_a?(Array)
      payload["messages"].filter_map do |message|
        next unless message.is_a?(Hash)
        role = message["role"].to_s
        content = estimate_inference_text(message["content"]).strip
        next if role.empty? || content.empty?

        {"role" => role, "content" => content}
      end
    elsif payload["message"] || payload["prompt"] || payload["input"]
      [{"role" => "user", "content" => (payload["message"] || payload["prompt"] || payload["input"]).to_s}]
    else
      []
    end
  end

  def ai_agent_user_query(messages)
    messages.reverse.find { it["role"] == "user" }&.fetch("content", nil).to_s
  end

  def ai_agent_cloudflare_payload(agent, model, messages, context_chunks, payload)
    system_prompt = [
      agent.system_prompt.to_s.strip,
      ai_agent_context_prompt(context_chunks),
    ].reject(&:empty?).join("\n\n")

    request_messages = messages.map { |message| {"role" => message["role"], "content" => message["content"]} }
    route = cloudflare_text_model_path(model)

    if route == "messages"
      request_payload = {
        "model" => model.model_name,
        "messages" => request_messages.reject { it["role"] == "system" },
        "system" => system_prompt.empty? ? nil : system_prompt,
        "stream" => false,
        "temperature" => payload["temperature"],
        "top_p" => payload["top_p"],
        "max_tokens" => payload["max_tokens"],
      }
      return request_payload.compact
    end

    if route == "responses"
      request_payload = {
        "model" => model.model_name,
        "input" => request_messages.reject { it["role"] == "system" },
        "instructions" => system_prompt.empty? ? nil : system_prompt,
        "stream" => false,
        "temperature" => payload["temperature"],
        "top_p" => payload["top_p"],
        "max_output_tokens" => payload["max_tokens"],
      }
      return request_payload.compact
    end

    if route == "run"
      request_payload = {
        "messages" => request_messages.reject { it["role"] == "system" },
        "system" => system_prompt.empty? ? nil : system_prompt,
        "stream" => false,
        "temperature" => payload["temperature"],
        "top_p" => payload["top_p"],
        "max_tokens" => payload["max_tokens"],
      }.compact
      return cloudflare_run_text_payload(model, request_payload)
    end

    request_messages.unshift({"role" => "system", "content" => system_prompt}) unless system_prompt.empty?

    {
      "model" => model.model_name,
      "messages" => request_messages,
      "stream" => false,
      "temperature" => payload["temperature"],
      "top_p" => payload["top_p"],
      "max_tokens" => payload["max_tokens"],
    }.compact
  end

  def ai_agent_context_prompt(context_chunks)
    return "" if context_chunks.empty?

    context = context_chunks.each_with_index.map do |chunk, index|
      "Source #{index + 1}: #{chunk.document.title}\n#{chunk.content}"
    end.join("\n\n")

    "Use this project knowledge when it is relevant. Do not invent details that are not supported by the context.\n\n#{context}"
  end

  def ai_agent_response_text(body)
    result = body["result"].is_a?(Hash) ? body["result"] : {}
    [
      body.dig("choices", 0, "message", "content"),
      body.dig("choices", 0, "text"),
      result.dig("choices", 0, "message", "content"),
      result.dig("choices", 0, "text"),
      result.dig("candidates", 0, "content", "parts", 0, "text"),
      body["output_text"],
      *Array(body["output"]).flat_map { |item| Array(item["content"]).map { |part| part["text"] if part.is_a?(Hash) } if item.is_a?(Hash) },
      *Array(body["content"]).map { |part| part["text"] if part.is_a?(Hash) },
      result["response"],
      result["text"],
      result["output_text"],
      *Array(result["output"]).flat_map { |item| Array(item["content"]).map { |part| part["text"] if part.is_a?(Hash) } if item.is_a?(Hash) },
      *Array(result["content"]).map { |part| part["text"] if part.is_a?(Hash) },
    ].compact.first.to_s
  end

  def record_ai_agent_event(agent, api_key, model, body, payload, latency_ms:, status:)
    prompt_tokens = estimate_inference_tokens(cloudflare_request_text(body, payload))
    completion_tokens = status == "ok" ? estimate_inference_tokens(ai_agent_response_text(body)) : 0
    AiAgentEvent.create(
      agent_id: agent.id,
      api_key_id: api_key.id,
      model_name: model.model_name,
      prompt_tokens:,
      completion_tokens:,
      status:,
      latency_ms:,
      error_message: status == "ok" ? nil : body.to_json[0, 1000],
    )
  rescue Sequel::Error => ex
    Clog.emit("Failed to record AI agent event", Util.exception_to_hash(ex, into: {agent_id: agent.id, project_id: agent.project_id}))
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
      payload["stream"] = !!payload["stream"]
    when "messages"
      messages = payload["messages"]
      fail CloverError.new(400, "InvalidRequest", "messages must be an array") unless messages.is_a?(Array)

      system_messages = []
      payload["messages"] = messages.filter_map do |message|
        next unless message.is_a?(Hash)

        content = estimate_inference_text(message["content"]).strip
        next if content.empty?

        if message["role"].to_s == "system"
          system_messages << content
          next
        end

        {"role" => message["role"].to_s, "content" => content}
      end

      payload["system"] = [payload["system"], system_messages].flatten.compact.map(&:to_s).reject(&:empty?).join("\n\n")
      payload.delete("system") if payload["system"].empty?
      payload["max_tokens"] ||= payload.delete("max_completion_tokens")
      payload["stream"] = false
    when "responses"
      if payload["messages"].is_a?(Array)
        messages = payload.delete("messages")
        instructions = []
        payload["input"] = messages.filter_map do |message|
          next unless message.is_a?(Hash)

          content = estimate_inference_text(message["content"]).strip
          next if content.empty?

          if message["role"].to_s == "system"
            instructions << content
            next
          end

          {"role" => message["role"].to_s, "content" => content}
        end
        payload["instructions"] = [payload["instructions"], instructions].flatten.compact.map(&:to_s).reject(&:empty?).join("\n\n")
        payload.delete("instructions") if payload["instructions"].empty?
      end

      fail CloverError.new(400, "InvalidRequest", "input or messages is required") unless payload.key?("input")
      payload["max_output_tokens"] ||= payload.delete("max_tokens") || payload.delete("max_completion_tokens") || 1024
      payload.delete("response_format")
      payload["stream"] = false
    when "embeddings"
      payload.delete("stream")
    end
  end

  def compact_cloudflare_payload!(value)
    case value
    when Hash
      value.keys.each do |key|
        compacted = compact_cloudflare_payload!(value[key])
        if compacted.nil? || (compacted.respond_to?(:empty?) && compacted.empty?)
          value.delete(key)
        else
          value[key] = compacted
        end
      end
      value
    when Array
      value.filter_map { compact_cloudflare_payload!(it) }
    else
      value
    end
  end

  def cloudflare_text_model_path(model)
    case model.tags["api"]
    when "messages"
      "messages"
    when "responses"
      "responses"
    when "run"
      "run"
    else
      "chat/completions"
    end
  end

  def cloudflare_run_request(client, model, payload)
    payload = cloudflare_run_text_payload(model, payload) if model.tags["capability"] == "Text Generation"
    return client.run_request(model.model_name, payload) if model.model_name.start_with?("@cf/", "@hf/")

    client.run_model_request(model.model_name, payload)
  end

  def stream_cloudflare_ai_request(api_key, model, payload)
    response.json = false
    response.status = 200
    response["Content-Type"] = "text/event-stream"
    response["Cache-Control"] = "no-cache, no-transform"
    response["X-Accel-Buffering"] = "no"

    prompt_tokens = estimate_inference_tokens(cloudflare_request_text({}, payload))
    completion_text = +""
    usage = {}
    body = Enumerator.new do |stream|
      CloudflareWorkersAiClient.new.openai_stream_request("chat/completions", payload) do |chunk|
        stream << chunk
        cloudflare_stream_events(chunk).each do |event|
          usage = event["usage"] if event["usage"].is_a?(Hash)
          completion_text << event.dig("choices", 0, "delta", "content").to_s
        end
      end
    ensure
      completion_tokens = (usage["completion_tokens"] || usage["output_tokens"]).to_i
      completion_tokens = estimate_inference_tokens(completion_text) if completion_tokens.zero?
      prompt_tokens = (usage["prompt_tokens"] || usage["input_tokens"]).to_i if (usage["prompt_tokens"] || usage["input_tokens"]).to_i.positive?
      record_inference_tokens(api_key, model, "input", model.prompt_billing_resource, prompt_tokens)
      record_inference_tokens(api_key, model, "output", model.completion_billing_resource, completion_tokens)
    end

    request.halt [200, response.headers, body]
  end

  def cloudflare_stream_events(chunk)
    chunk.to_s.each_line.filter_map do |line|
      next unless line.start_with?("data:")

      data = line.delete_prefix("data:").strip
      next if data.empty? || data == "[DONE]"

      JSON.parse(data)
    rescue JSON::ParserError
      nil
    end
  end

  def cloudflare_run_text_payload(model, payload)
    if model.model_name.start_with?("google/")
      messages = payload["messages"] || []
      contents = messages.filter_map do |message|
        content = estimate_inference_text(message["content"]).strip
        next if content.empty?

        {"role" => message["role"] == "assistant" ? "model" : "user", "parts" => [{"text" => content}]}
      end
      system = estimate_inference_text(payload["system"]).strip
      contents.unshift({"role" => "user", "parts" => [{"text" => system}]}) unless system.empty?

      return {
        "contents" => contents,
        "generationConfig" => {
          "temperature" => payload["temperature"],
          "topP" => payload["top_p"],
          "maxOutputTokens" => payload["max_tokens"],
        }.compact,
      }.compact
    end

    payload
  end

  def record_cloudflare_inference_usage(api_key, model, body, payload)
    result = body["result"].is_a?(Hash) ? body["result"] : {}
    usage = body["usage"] || result["usage"] || {}
    prompt_tokens = (usage["prompt_tokens"] || usage["input_tokens"]).to_i
    completion_tokens = (usage["completion_tokens"] || usage["output_tokens"]).to_i
    total_tokens = usage["total_tokens"].to_i

    prompt_tokens = estimate_inference_tokens(cloudflare_request_text(body, payload)) if prompt_tokens.zero?
    completion_tokens = [total_tokens - prompt_tokens, 0].max if completion_tokens.zero? && total_tokens.positive?
    completion_tokens = estimate_inference_tokens(cloudflare_response_text(body)) if completion_tokens.zero? && !["Embeddings", "Text-to-Image", "Text-to-Speech"].include?(model.tags["capability"])

    record_inference_tokens(api_key, model, "input", model.prompt_billing_resource, prompt_tokens)
    record_inference_tokens(api_key, model, "output", model.completion_billing_resource, completion_tokens)
  end

  def validate_premium_ai_access!(api_key, model)
    return unless Config.premium_ai_metering_enabled
    return unless PremiumAiUsageMeter.premium_model?(model)
    return if PremiumAiTrial.active_for?(api_key.project, model)

    fail CloverError.new(402, "BillingRequired", "Premium AI models require billing to be connected before use.") unless api_key.project.billing_info&.polar_external_customer_id || api_key.project.billing_info

    cap = Config.premium_ai_monthly_spend_cap_cents.to_i
    return unless cap.positive?

    if PremiumAiUsageMeter.current_month_premium_usage_cents(api_key.project) >= cap
      fail CloverError.new(402, "PremiumAISpendCapExceeded", "Premium AI usage is paused because this project reached its premium AI spend cap.")
    end
  end

  def record_inference_tokens(api_key, model, token_kind, resource_family, tokens)
    return unless tokens.positive?

    rate = BillingRate.from_resource_properties("InferenceTokens", resource_family, "global")
    trial = PremiumAiTrial.active_for?(api_key.project, model)
    PremiumAiUsageMeter.record(api_key:, model:, token_kind:, resource_family:, tokens:, billing_rate: rate) unless trial
    return unless rate

    begin_time = Time.now.to_date.to_time
    end_time = begin_time + 24 * 60 * 60
    today_record = BillingRecord
      .where(project_id: api_key.project_id, resource_id: api_key.id, billing_rate_id: rate["id"])
      .where(Sequel.pg_jsonb_op(:resource_tags).contains({"premium_ai_trial" => trial}))
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
        resource_tags: {
          provider: model.provider,
          model: model.model_name,
          token_kind:,
          premium_ai: PremiumAiUsageMeter.premium_model?(model),
          premium_ai_trial: trial
        },
      )
    end
  rescue Sequel::Error => ex
    Clog.emit("Failed to update Cloudflare inference billing record", Util.exception_to_hash(ex, into: {project_id: api_key.project_id, resource_family:, tokens:}))
  end

  def inference_model_million_token_price(model, resource)
    BillingRate.million_token_price(resource) || model.tags["pricing"]&.dig(resource.end_with?("-input") ? "input" : "output")
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
      payload["instructions"],
      payload["system"],
      payload["query"],
      payload["contexts"],
    ].compact
  end

  def cloudflare_response_text(body)
    result = body["result"].is_a?(Hash) ? body["result"] : {}
    [
      body.dig("choices", 0, "message", "content"),
      body.dig("choices", 0, "text"),
      result.dig("choices", 0, "message", "content"),
      result.dig("choices", 0, "text"),
      result.dig("candidates", 0, "content", "parts", 0, "text"),
      body["output_text"],
      *Array(body["output"]).flat_map { |item| Array(item["content"]).map { |part| part["text"] if part.is_a?(Hash) } if item.is_a?(Hash) },
      *Array(body["content"]).map { |part| part["text"] if part.is_a?(Hash) },
      result["response"],
      result["text"],
      result["output_text"],
      *Array(result["output"]).flat_map { |item| Array(item["content"]).map { |part| part["text"] if part.is_a?(Hash) } if item.is_a?(Hash) },
      *Array(result["content"]).map { |part| part["text"] if part.is_a?(Hash) },
      result["translated_text"],
      result["summary"],
      result["description"],
      *Array(body["result"]).map { it.is_a?(Hash) ? [it["label"], it["score"]].compact.join(" ") : nil },
    ].compact.join("\n")
  end

  def openai_model_entry(model)
    owned_by = if model.respond_to?(:provider)
      model.provider
    else
      model.tags.fetch("provider", "layerrail")
    end

    {
      "id" => model.model_name,
      "object" => "model",
      "created" => 1_700_000_000,
      "owned_by" => owned_by,
    }
  end
end
