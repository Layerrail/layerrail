# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "ai-app") do |r|
    unless Config.ai_inference_enabled
      response.status = 501
      response.content_type = :text
      next "AI Models are not enabled. Set AI_INFERENCE_ENABLED=true after configuring the inference provider."
    end

    r.get api? do
      {
        agents: @project.ai_agents_dataset.order(:name).map { ai_agent_json(it) },
        knowledge_bases: @project.ai_knowledge_bases_dataset.order(:name).map { ai_knowledge_base_json(it) },
      }
    end

    r.get true do
      load_ai_app_page
      view "inference/app/index"
    end

    r.post "knowledge-base" do
      handle_validation_failure("inference/app/index")
      load_ai_app_page
      authorize("Project:edit", @project)

      kb = AiKnowledgeBase.create(
        project_id: @project.id,
        name: AiAgent.slugify(typecast_params.nonempty_str!("name")),
        description: typecast_params.str("description").to_s.strip,
      )
      audit_log(kb, "create")
      flash["notice"] = "Knowledge base created"
      r.redirect "#{@project.path}/ai-app?tab=knowledge"
    end

    r.post "knowledge-base", :ubid_uuid, "document" do |knowledge_base_id|
      handle_validation_failure("inference/app/index")
      load_ai_app_page
      authorize("Project:edit", @project)

      kb = @project.ai_knowledge_bases_dataset.first(id: knowledge_base_id)
      check_found_object(kb)
      document = AiKnowledgeDocument.create(
        knowledge_base_id: kb.id,
        title: typecast_params.nonempty_str!("title").strip,
        source_type: typecast_params.str("source_type").to_s.empty? ? "text" : typecast_params.str("source_type").to_s,
        source_url: ai_app_blank_to_nil(typecast_params.str("source_url")),
        content: typecast_params.nonempty_str!("content"),
      )
      document.refresh_chunks!
      audit_log(document, "create")
      flash["notice"] = "Document added to #{kb.name}"
      r.redirect "#{@project.path}/ai-app?tab=knowledge"
    end

    r.post true do
      handle_validation_failure("inference/app/index")
      load_ai_app_page
      authorize("Project:edit", @project)

      model_name = typecast_params.nonempty_str!("model_name")
      unless ai_app_text_model_names.include?(model_name)
        fail Validation::ValidationFailed.new({model_name: "is not available for app endpoints"})
      end

      template = ai_app_template(typecast_params.str("template"))
      knowledge_base_id = ai_app_blank_to_nil(typecast_params.str("knowledge_base_id"))&.then { typecast_params.ubid_uuid("knowledge_base_id") }
      knowledge_base = knowledge_base_id && @project.ai_knowledge_bases_dataset.first(id: knowledge_base_id)
      fail Validation::ValidationFailed.new({knowledge_base_id: "does not exist"}) if knowledge_base_id && !knowledge_base

      name = AiAgent.slugify(typecast_params.nonempty_str!("name"))
      agent = AiAgent.create(
        project_id: @project.id,
        knowledge_base_id: knowledge_base&.id,
        name:,
        public_slug: AiAgent.slugify(typecast_params.str("public_slug").to_s.empty? ? name : typecast_params.str("public_slug")),
        description: typecast_params.str("description").to_s.strip,
        model_name:,
        system_prompt: ai_app_blank_to_nil(typecast_params.str("system_prompt")) || template[:prompt],
        template: template[:id],
        tools: template[:tools],
      )
      audit_log(agent, "create")
      flash["notice"] = "App endpoint created"
      r.redirect path(agent)
    end

    show_ai_agent = lambda do |name, id|
      matched_id = id || (UBID.to_uuid(name) if name)
      @ai_agent = matched_id ? @project.ai_agents_dataset.first(id: matched_id) : @project.ai_agents_dataset.first(public_slug: name)
      check_found_object(@ai_agent)
      authorize("Project:view", @project)

      r.get true do
        @events = @ai_agent.events_dataset.limit(20).all
        @inference_api_keys = inference_api_key_ds.all
        view "inference/app/show"
      end

      r.post "delete" do
        authorize("Project:edit", @project)
        DB.transaction do
          @ai_agent.destroy
          audit_log(@ai_agent, "destroy")
        end
        flash["notice"] = "App endpoint deleted"
        r.redirect "#{@project.path}/ai-app"
      end
    end

    r.on :ubid_uuid do |id|
      show_ai_agent.call(nil, id)
    end

    r.on /([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)/ do |name|
      show_ai_agent.call(name, nil)
    end
  end

  def load_ai_app_page
    @ai_agents = ai_agent_ds.all
    @ai_knowledge_bases = ai_knowledge_base_ds.all
    @ai_app_templates = AI_APP_TEMPLATES
    @ai_app_text_models = ai_app_text_models
    @inference_api_keys = inference_api_key_ds.all
    @remaining_free_quota = FreeQuota.remaining_free_quota("inference-tokens", @project.id)
    @free_quota_unit = "inference tokens"
    @has_valid_payment_method = @project.has_valid_payment_method?
  end

  def ai_app_text_models
    @ai_app_text_models ||= all_inference_models.select { it.tags["capability"] == "Text Generation" }
  end

  def ai_app_text_model_names
    ai_app_text_models.map(&:model_name)
  end

  def ai_app_template(template_id)
    AI_APP_TEMPLATES.find { it[:id] == template_id } || AI_APP_TEMPLATES.first
  end

  def ai_app_blank_to_nil(value)
    value = value.to_s.strip
    value.empty? ? nil : value
  end

  def ai_agent_json(agent)
    {
      id: agent.ubid,
      name: agent.name,
      status: agent.status,
      model: agent.model_name,
      endpoint: agent.public_url,
      knowledge_base_id: agent.knowledge_base&.ubid,
    }
  end

  def ai_knowledge_base_json(kb)
    {
      id: kb.ubid,
      name: kb.name,
      status: kb.status,
      documents: kb.document_count,
      chunks: kb.chunk_count,
    }
  end
end
