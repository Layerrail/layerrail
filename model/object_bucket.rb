# frozen_string_literal: true

require_relative "../model"

class ObjectBucket < Sequel::Model
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_one :minio_cluster, read_only: true
  one_to_one :strand, key: :id

  plugin ResourceMethods, etc_type: true, encrypted_columns: :secret_key
  plugin SemaphoreMethods, :destroy

  def path
    "/bucket/#{name}"
  end

  def display_location
    location.ui_name
  end

  def ready?
    state == "ready"
  end

  def self.generate_bucket_name(project, name)
    "#{project.ubid}-#{name}".downcase.gsub(/[^a-z0-9-]/, "-")[0, 63].delete_suffix("-")
  end
end

# Table: object_bucket
