# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "volume") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        @block_volumes = @project.block_volumes_dataset.eager(:location, :attached_vm).reverse(:created_at).all
        vm_ids = @project.vms_dataset.select(:id)
        @attached_volumes = VmStorageVolume
          .where(vm_id: vm_ids)
          .eager({vm: :location}, :azure_storage_volume, :linode_storage_volume, :storage_device)
          .association_join(:vm)
          .order(Sequel[:vm][:name], Sequel[:vm_storage_volume][:disk_index])
          .all
        view "volume/index"
      end

      r.get "create" do
        @locations = BlockVolume.available_locations
        view "volume/create"
      end

      r.post true do
        authorize("Project:billing", @project)
        handle_validation_failure("volume/create")
        name = typecast_params.nonempty_str!("name").downcase
        Validation.validate_name(name)
        size_gib = typecast_params.pos_int!("size_gib")
        raise_web_error("Volume size must be between 10 GB and 4096 GB.") unless (10..4096).cover?(size_gib)

        location = Location[typecast_params.nonempty_str!("location_id")]
        check_found_object(location)
        raise_web_error("Block volumes are not available in #{location.ui_name}.") unless BlockVolume.available_locations.map(&:id).include?(location.id)
        raise_web_error("A volume named #{name} already exists.") if @project.block_volumes_dataset.where(name:).count.positive?

        volume = nil
        DB.transaction do
          volume = BlockVolume.create(
            project_id: @project.id,
            location_id: location.id,
            name:,
            provider: "azure",
            provider_volume_name: BlockVolume.generate_provider_name(@project, name),
            size_gib:
          )
          Prog::BlockVolumeNexus.assemble(volume)
          audit_log(volume, "create")
        end

        flash["notice"] = "Volume #{name} is being created."
        r.redirect "#{@project.path}#{volume.path}"
      end

      r.on String do |name|
        @block_volume = volume = @project.block_volumes_dataset.first(name:)
        check_found_object(volume)

        r.get true do
          @attachable_vms = @project.vms_dataset
            .where(location_id: volume.location_id)
            .exclude(id: volume.attached_vm_id)
            .eager(:location, :azure_instance)
            .all
            .select(&:azure_instance)
          view "volume/show"
        end

        r.post "attach" do
          authorize("Project:billing", @project)
          raise_web_error("Volume is not available for attach.") unless volume.attachable?
          vm = @project.vms_dataset.first(id: typecast_params.nonempty_str!("vm_id"))
          check_found_object(vm)
          volume.strand.stack[0]["attach_vm_id"] = vm.id
          volume.incr_attach
          audit_log(volume, "attach")
          flash["notice"] = "Volume #{volume.name} is being attached."
          r.redirect "#{@project.path}#{volume.path}"
        end

        r.post "detach" do
          authorize("Project:billing", @project)
          raise_web_error("Volume is not attached.") unless volume.detachable?
          volume.incr_detach
          audit_log(volume, "detach")
          flash["notice"] = "Volume #{volume.name} is being detached."
          r.redirect "#{@project.path}#{volume.path}"
        end

        r.post "delete" do
          authorize("Project:billing", @project)
          DB.transaction do
            if volume.state == "failed" && volume.provider_volume_id.nil?
              BillingRecord.finalize_active_for_resource(volume)
              volume.destroy
            else
              volume.incr_destroy
            end
            audit_log(volume, "destroy")
          end
          flash["notice"] = "Volume #{volume.name} scheduled for deletion."
          r.redirect "#{@project.path}/volume"
        end
      end
    end
  end
end
