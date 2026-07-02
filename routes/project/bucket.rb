# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "bucket") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        @buckets = @project.object_buckets_dataset.eager(:location).all
        view "bucket/index"
      end

      r.get "create" do
        @locations = ObjectBucket.available_locations
        view "bucket/create"
      end

      r.post true do
        handle_validation_failure("bucket/create")
        name = typecast_params.nonempty_str!("name").downcase
        Validation.validate_name(name)

        location = Location[typecast_params.nonempty_str!("location_id")]
        check_found_object(location)
        raise_web_error("Object storage is not available in #{location.ui_name}.") unless ObjectBucket.available_locations.map(&:id).include?(location.id)
        raise_web_error("A bucket named #{name} already exists.") if @project.object_buckets_dataset.where(name:).count.positive?

        bucket = nil
        DB.transaction do
          bucket = ObjectBucket.create(
            project_id: @project.id,
            location_id: location.id,
            name:,
            bucket_name: ObjectBucket.generate_bucket_name(@project, name),
            access_key: SecureRandom.hex(16),
            secret_key: SecureRandom.hex(32),
          )
          Prog::ObjectBucketNexus.assemble(bucket)
          audit_log(bucket, "create")
        end

        flash["notice"] = "Bucket #{name} is being created."
        r.redirect "#{@project.path}#{bucket.path}"
      end

      r.on String do |name|
        @bucket = bucket = @project.object_buckets_dataset.first(name:)
        check_found_object(bucket)

        r.get true do
          view "bucket/show"
        end

        r.post "delete" do
          authorize("Project:billing", @project)
          DB.transaction do
            if bucket.state == "failed" && bucket.minio_cluster_id.nil?
              BillingRecord.finalize_active_for_resource(bucket)
              bucket.destroy
            else
              bucket.incr_destroy
            end
            audit_log(bucket, "destroy")
          end
          flash["notice"] = "Bucket #{bucket.name} scheduled for deletion."
          r.redirect "#{@project.path}/bucket"
        end
      end
    end
  end
end
