# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Linode
    def linode_volume_label
      "lr-#{ubid}"
    end

    private

    def linode_device_path
      return "/dev/sda" if boot

      linode_storage_volume&.filesystem_path || "/dev/disk/by-id/scsi-0Linode_Volume_#{linode_volume_label}"
    end
  end
end
