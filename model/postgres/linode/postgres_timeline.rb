# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Linode
    private

    def linode_generate_walg_config(version)
      metal_generate_walg_config(version)
    end

    def linode_walg_config_region
      metal_walg_config_region
    end

    def linode_blob_storage
      metal_blob_storage
    end

    def linode_blob_storage_client
      metal_blob_storage_client
    end

    def linode_list_objects(prefix, delimiter: "")
      metal_list_objects(prefix, delimiter:)
    end

    def linode_create_bucket
      metal_create_bucket
    end

    def linode_set_lifecycle_policy
      metal_set_lifecycle_policy
    end

    def linode_destroy_blob_storage
      metal_destroy_blob_storage
    end

    def linode_setup_blob_storage
      metal_setup_blob_storage
    end

    def linode_generate_blob_storage_credentials?
      metal_generate_blob_storage_credentials?
    end
  end
end

