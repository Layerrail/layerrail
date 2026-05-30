# frozen_string_literal: true

require_relative "../model"

class DeployVariable < Sequel::Model(:deploy_variable)
  one_to_one :strand, key: :id
  many_to_one :app, class: :DeployApp, key: :app_id, read_only: true

  plugin ResourceMethods, encrypted_columns: :value

  def validate
    super
    validates_format(/\A[A-Z_][A-Z0-9_]{0,127}\z/, :key, message: "must start with a letter or underscore and contain only uppercase letters, numbers and underscores")
    validates_max_length(16_384, :value)
  end
end
