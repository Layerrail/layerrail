# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:ai_knowledge_base) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, String, null: false, collate: '"C"'
      column :description, String, null: false, default: ""
      column :embedding_model, String, null: false, default: "@cf/baai/bge-base-en-v1.5", collate: '"C"'
      column :status, String, null: false, default: "ready", collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index :project_id
    end

    create_table(:ai_knowledge_document) do
      column :id, :uuid, primary_key: true
      foreign_key :knowledge_base_id, :ai_knowledge_base, type: :uuid, null: false
      column :title, String, null: false
      column :source_type, String, null: false, default: "text", collate: '"C"'
      column :source_url, String
      column :content, String, null: false
      column :status, String, null: false, default: "ready", collate: '"C"'
      column :metadata, :jsonb, null: false, default: "{}"
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index :knowledge_base_id
    end

    create_table(:ai_knowledge_chunk) do
      column :id, :uuid, primary_key: true
      foreign_key :document_id, :ai_knowledge_document, type: :uuid, null: false
      column :ordinal, Integer, null: false
      column :content, String, null: false
      column :embedding, :jsonb
      column :token_count, Integer, null: false, default: 0
      column :metadata, :jsonb, null: false, default: "{}"
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:document_id, :ordinal], unique: true
      index :document_id
    end

    create_table(:ai_agent) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :knowledge_base_id, :ai_knowledge_base, type: :uuid, on_delete: :set_null
      column :name, String, null: false, collate: '"C"'
      column :public_slug, String, null: false, collate: '"C"'
      column :description, String, null: false, default: ""
      column :model_name, String, null: false, default: "@cf/meta/llama-3.1-8b-instruct", collate: '"C"'
      column :system_prompt, String, null: false, default: ""
      column :tools, :jsonb, null: false, default: "[]"
      column :template, String, null: false, default: "custom", collate: '"C"'
      column :status, String, null: false, default: "active", collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:project_id, :name], unique: true
      index [:project_id, :public_slug], unique: true
      index :knowledge_base_id
      index :project_id
    end

    create_table(:ai_agent_event) do
      column :id, :uuid, primary_key: true
      foreign_key :agent_id, :ai_agent, type: :uuid, null: false
      foreign_key :api_key_id, :api_key, type: :uuid, on_delete: :set_null
      column :model_name, String, null: false, collate: '"C"'
      column :prompt_tokens, Integer, null: false, default: 0
      column :completion_tokens, Integer, null: false, default: 0
      column :status, String, null: false, default: "ok", collate: '"C"'
      column :latency_ms, Integer
      column :error_message, String
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")

      index [:agent_id, :created_at]
      index :api_key_id
    end

    run <<~SQL
      ALTER TABLE ai_knowledge_base
        ADD CONSTRAINT valid_ai_knowledge_base_status
        CHECK (status IN ('ready', 'disabled'));

      ALTER TABLE ai_knowledge_document
        ADD CONSTRAINT valid_ai_knowledge_document_source_type
        CHECK (source_type IN ('text', 'url', 'api'));

      ALTER TABLE ai_knowledge_document
        ADD CONSTRAINT valid_ai_knowledge_document_status
        CHECK (status IN ('ready', 'disabled'));

      ALTER TABLE ai_knowledge_chunk
        ADD CONSTRAINT valid_ai_knowledge_chunk_ordinal
        CHECK (ordinal >= 0);

      ALTER TABLE ai_agent
        ADD CONSTRAINT valid_ai_agent_status
        CHECK (status IN ('active', 'disabled'));

      ALTER TABLE ai_agent
        ADD CONSTRAINT valid_ai_agent_slug
        CHECK (public_slug ~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

      ALTER TABLE ai_agent_event
        ADD CONSTRAINT valid_ai_agent_event_status
        CHECK (status IN ('ok', 'error'));
    SQL
  end

  down do
    drop_table(:ai_agent_event)
    drop_table(:ai_agent)
    drop_table(:ai_knowledge_chunk)
    drop_table(:ai_knowledge_document)
    drop_table(:ai_knowledge_base)
  end
end
