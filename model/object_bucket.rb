# frozen_string_literal: true

require_relative "../model"

class ObjectBucket < Sequel::Model
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_one :minio_cluster, read_only: true
  one_to_one :strand, key: :id

  plugin ResourceMethods, etc_type: true, encrypted_columns: :secret_key
  plugin SemaphoreMethods, :destroy, :usage_limit_suspended, :usage_limit_resume

  def path
    "/bucket/#{name}"
  end

  def display_location
    location.ui_name
  end

  def ready?
    state == "ready" && !usage_limit_suspended_set?
  end

  def billing_amount_gib
    1
  end

  def public_region
    location.name.to_s.delete_prefix("azure-")
  end

  def s3_endpoint
    "https://s3.#{public_region}.#{Config.object_storage_public_domain}"
  end

  def s3_url
    "#{s3_endpoint}/#{bucket_name}"
  end

  def public_url
    "https://#{name}.#{project.ubid}.s3.#{public_region}.#{Config.object_storage_public_domain}/"
  end

  def ensure_billing_record!
    rate = BillingRate.from_resource_properties("ObjectBucketStorage", "standard", "global")
    fail "Object bucket billing rate is not configured" unless rate

    return if BillingRecord.where(resource_id: id, billing_rate_id: rate.fetch("id")).active.first

    BillingRecord.create(
      project_id: project_id,
      resource_id: id,
      resource_name: name,
      amount: billing_amount_gib,
      billing_rate_id: rate.fetch("id"),
      resource_tags: Sequel.pg_jsonb_wrap({"service" => "object-bucket", "bucket_name" => bucket_name})
    )
  end

  def self.generate_bucket_name(project, name)
    "#{project.ubid}-#{name}".downcase.gsub(/[^a-z0-9-]/, "-")[0, 63].delete_suffix("-")
  end

  def self.available_locations
    MinioCluster
      .where(project_id: [Config.minio_service_project_id, Config.postgres_service_project_id].compact)
      .select_map(:location_id)
      .uniq
      .then { |ids| ids.empty? ? [] : Location.where(id: ids, visible: true).order(:ui_name).all }
  end
end

# Table: object_bucket
