# frozen_string_literal: true

require_relative "../model"

class DeployVariable < Sequel::Model(:deploy_variable)
  one_to_one :strand, key: :id
  many_to_one :app, class: :DeployApp, read_only: true

  plugin ResourceMethods, encrypted_columns: :value

  def validate
    super
    validates_format(/\A[A-Z_][A-Z0-9_]{0,127}\z/, :key, message: "must start with a letter or underscore and contain only uppercase letters, numbers and underscores")
    validates_max_length(16_384, :value)
  end
end

# Table: deploy_variable
# Columns:
#  id         | uuid                     | PRIMARY KEY
#  app_id     | uuid                     | NOT NULL
#  key        | text                     | NOT NULL
#  value      | text                     | NOT NULL
#  created_at | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  deploy_variable_pkey             | PRIMARY KEY btree (id)
#  deploy_variable_app_id_key_index | UNIQUE btree (app_id, key)
#  deploy_variable_app_id_index     | btree (app_id)
# Foreign key constraints:
#  deploy_variable_app_id_fkey | (app_id) REFERENCES deploy_app(id)
