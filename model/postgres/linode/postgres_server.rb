# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Linode
    private

    def linode_add_provider_configs(configs)
      nil
    end

    def linode_refresh_walg_blob_storage_credentials
      metal_refresh_walg_blob_storage_credentials
    end

    def linode_storage_device_paths
      vm.vm_storage_volumes.reject(&:boot).sort_by!(&:disk_index).map!(&:device_path)
    end

    def linode_attach_s3_policy_if_needed
      nil
    end

    def linode_increment_s3_new_timeline
    end
  end
end
