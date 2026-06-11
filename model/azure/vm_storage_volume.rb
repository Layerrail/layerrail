# frozen_string_literal: true

class VmStorageVolume < Sequel::Model
  module Azure
    def azure_disk_name
      "lr-#{ubid}"
    end

    private

    def azure_device_path
      return "/dev/sda" if boot

      azure_storage_volume&.device_path || "/dev/disk/azure/scsi1/lun#{disk_index - 1}"
    end
  end
end
