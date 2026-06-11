# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Azure
    private

    def azure_add_provider_configs(configs)
      nil
    end

    def azure_refresh_walg_blob_storage_credentials
      metal_refresh_walg_blob_storage_credentials
    end

    def azure_storage_device_paths
      vm.vm_storage_volumes.reject(&:boot).sort_by!(&:disk_index).map!(&:device_path)
    end

    def azure_attach_s3_policy_if_needed
      nil
    end

    def azure_increment_s3_new_timeline
    end
  end
end
