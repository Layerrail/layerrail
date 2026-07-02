# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "volume") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        vm_ids = @project.vms_dataset.select(:id)
        @volumes = VmStorageVolume
          .where(vm_id: vm_ids)
          .eager({vm: :location}, :azure_storage_volume, :linode_storage_volume, :storage_device)
          .association_join(:vm)
          .order(Sequel[:vm][:name], Sequel[:vm_storage_volume][:disk_index])
          .all

        view "volume/index"
      end
    end
  end
end
