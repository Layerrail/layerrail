# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Azure
    private

    def azure_generate_walg_config(version)
      metal_generate_walg_config(version)
    end

    def azure_walg_config_region
      metal_walg_config_region
    end

    def azure_blob_storage
      metal_blob_storage
    end

    def azure_blob_storage_client
      metal_blob_storage_client
    end

    def azure_list_objects(prefix, delimiter: "")
      metal_list_objects(prefix, delimiter:)
    end

    def azure_create_bucket
      metal_create_bucket
    end

    def azure_set_lifecycle_policy
      metal_set_lifecycle_policy
    end

    def azure_destroy_blob_storage
      metal_destroy_blob_storage
    end

    def azure_setup_blob_storage
      metal_setup_blob_storage
    end

    def azure_generate_blob_storage_credentials?
      metal_generate_blob_storage_credentials?
    end
  end
end
