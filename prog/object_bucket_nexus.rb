# frozen_string_literal: true

class Prog::ObjectBucketNexus < Prog::Base
  subject_is :object_bucket

  def self.assemble(bucket)
    Strand.create_with_id(bucket, prog: "ObjectBucketNexus", label: "start", stack: [{subject_id: bucket.id}])
  end

  label def start
    pop "object bucket missing" unless object_bucket
    when_destroy_set? { hop_destroy }
    cluster = storage_cluster
    unless cluster
      object_bucket.update(state: "failed", last_error: "No object storage cluster is available in #{object_bucket.display_location}.")
      nap 6 * 60 * 60
    end

    object_bucket.update(minio_cluster_id: cluster.id, endpoint: cluster.url || cluster.ip4_urls.first)
    nap 60 unless cluster.strand&.label == "wait"

    admin_client.admin_add_user(object_bucket.access_key, object_bucket.secret_key)
    admin_client.admin_policy_add(object_bucket.ubid, bucket_policy)
    admin_client.admin_policy_set(object_bucket.ubid, object_bucket.access_key)
    bucket_client.create_bucket(object_bucket.bucket_name)
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    if ex.message.include?("BucketAlreadyOwnedByYou") || ex.message.include?("Your previous request to create the named bucket succeeded")
      object_bucket.update(state: "ready", last_error: nil)
      object_bucket.ensure_billing_record!
      hop_wait
    end

    object_bucket.update(state: "failed", last_error: ex.message)
    Clog.emit("Object bucket provision failed", Util.exception_to_hash(ex).merge(object_bucket_id: object_bucket.id))
    nap 30 * 60
  else
    object_bucket.update(state: "ready", last_error: nil)
    object_bucket.ensure_billing_record!
    hop_wait
  end

  label def wait
    when_destroy_set? { hop_destroy }
    nap 6 * 60 * 60
  end

  label def destroy
    decr_destroy
    object_bucket.update(state: "deleting")
    begin
      bucket_client.delete_bucket(object_bucket.bucket_name) if object_bucket.minio_cluster
    rescue => ex
      raise unless ex.message.include?("NoSuchBucket") || ex.message.include?("does not exist")
    end

    if object_bucket.minio_cluster
      admin_client.admin_remove_user(object_bucket.access_key)
      admin_client.admin_policy_remove(object_bucket.ubid)
    end
    BillingRecord.finalize_active_for_resource(object_bucket)
    object_bucket.destroy
    pop "object bucket destroyed"
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    object_bucket.update(state: "failed", last_error: ex.message)
    Clog.emit("Object bucket delete failed", Util.exception_to_hash(ex).merge(object_bucket_id: object_bucket.id))
    nap 30 * 60
  end

  private

  def storage_cluster
    @storage_cluster ||= MinioCluster.where(
      project_id: [Config.minio_service_project_id, Config.postgres_service_project_id].compact,
      location_id: object_bucket.location_id,
    ).order(project_id: Config.minio_service_project_id).last
  end

  def bucket_policy
    {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{object_bucket.bucket_name}*"]}]}
  end

  def bucket_client
    @bucket_client ||= Minio::Client.new(
      endpoint: object_bucket.endpoint,
      access_key: object_bucket.access_key,
      secret_key: object_bucket.secret_key,
      ssl_ca_data: object_bucket.minio_cluster.root_certs,
    )
  end

  def admin_client
    @admin_client ||= Minio::Client.new(
      endpoint: object_bucket.endpoint,
      access_key: object_bucket.minio_cluster.admin_user,
      secret_key: object_bucket.minio_cluster.admin_password,
      ssl_ca_data: object_bucket.minio_cluster.root_certs,
    )
  end
end
