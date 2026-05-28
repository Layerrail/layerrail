# frozen_string_literal: true

class Clover
  def authorized_vm(perm: "Vm:view", location_id: nil)
    authorized_object(association: :vms, key: "vm_id", perm:, location_id:)
  end

  def vm_list
    dataset = dataset_authorize(@project.vms_dataset, "Vm:view")
      .eager(:strand, :semaphores, :assigned_vm_address, :vm_storage_volumes, :location)

    if api?
      dataset = dataset.where(location_id: @location.id) if @location
      paginated_result(dataset, Serializers::Vm)
    else
      @vms = dataset
        .reverse(:created_at)
        .all
      view "vm/index"
    end
  end

  def vm_post(name)
    project = @project
    authorize("Vm:create", project)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless project.has_valid_payment_method?
    if Config.compute_provider && @location.provider != Config.compute_provider
      fail Validation::ValidationFailed.new({location: "LayerRail compute is configured for #{Config.compute_provider}, but #{@location.ui_name} uses #{@location.provider}."})
    end

    if api?
      public_key = typecast_params.nonempty_str!("public_key")
      if !public_key.include?(" ") && (ssh_public_key = project.ssh_public_keys_dataset.first(name: public_key))
        public_key = ssh_public_key.public_key
      end
    else
      public_key = if (spk_id = typecast_params.ubid_uuid("ssh_public_key")) && (ssh_public_key = project.ssh_public_keys_dataset.first(id: spk_id))
        ssh_public_key.public_key
      else
        typecast_params.nonempty_str!("public_key")
      end
    end

    assemble_params = typecast_params.convert!(symbolize: true) do |tp|
      tp.nonempty_str(["size", "unix_user", "boot_image", "private_subnet_id", "gpu", "init_script"])
      tp.pos_int("storage_size")
      tp.bool("enable_ip4")
    end
    assemble_params.compact!
    parsed_size = nil
    gpu_count = 0
    gpu_device = nil

    # Generally parameter validation is handled in progs while creating resources.
    # Since Vm::Nexus both handles VM creation requests from user and also Postgres
    # service, moved the boot_image validation here to not allow users to pass
    # postgres image as boot image while creating a VM.
    if assemble_params[:boot_image]
      Validation.validate_boot_image(assemble_params[:boot_image])
      Option.linode_image_name(assemble_params[:boot_image]) if @location.linode?
    end

    # Same as above, moved the size validation here to not allow users to
    # pass gpu instance while creating a VM.
    if assemble_params[:size]
      parsed_size = Validation.validate_vm_size(assemble_params[:size], "x64", only_visible: true)
    end

    if assemble_params[:gpu]
      gpu_count, gpu_device = Validation.validate_vm_gpu(assemble_params[:gpu], @location.name, project, parsed_size)
      assemble_params[:gpu_count] = gpu_count
      assemble_params[:gpu_device] = gpu_device
      assemble_params.delete(:gpu)
    end

    if @location.linode? && gpu_count.positive?
      unless Option.linode_gpu_location?(@location.name)
        fail Validation::ValidationFailed.new({location: "Linode GPU VMs are available in Frankfurt, DE and Seattle, WA."})
      end

      assemble_params[:boot_image] ||= "gpu-ubuntu-noble"
      unless assemble_params[:boot_image] == "gpu-ubuntu-noble"
        fail Validation::ValidationFailed.new({boot_image: "Linode GPU VMs use Ubuntu 24.04 for GPU VMs."})
      end
    end

    if @location.linode?
      linode_size = parsed_size || Validation.validate_vm_size(Prog::Vm::Nexus::DEFAULT_SIZE, "x64", only_visible: true)
      plan = Option.linode_plan(
        linode_size.family,
        linode_size.vcpus,
        gpu_count:,
        gpu_device:,
        size_name: linode_size.display_name,
      )

      if assemble_params[:storage_size] && assemble_params[:storage_size] != plan.disk_gib
        fail Validation::ValidationFailed.new({storage_size: "Linode #{plan.label} includes #{plan.disk_gib} GB storage. Custom root disk sizes are not enabled yet."})
      end
      assemble_params[:storage_volumes] = [{size_gib: plan.disk_gib, encrypted: true}]
      assemble_params.delete(:storage_size)
    elsif assemble_params[:storage_size]
      storage_size = Validation.validate_vm_storage_size(assemble_params[:size] || Prog::Vm::Nexus::DEFAULT_SIZE, "x64", assemble_params[:storage_size])
      assemble_params[:storage_volumes] = [{size_gib: storage_size, encrypted: true}]
      assemble_params.delete(:storage_size)
    end

    if (ps_id = assemble_params[:private_subnet_id])
      if web? && ps_id.start_with?("new-")
        assemble_params[:private_subnet_id] = nil
        ps_name = typecast_params.nonempty_str!("new_private_subnet_name")
        unless ps_name.match(Validation::ALLOWED_NAME_PATTERN)
          fail Validation::ValidationFailed.new({new_private_subnet_name: "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."})
        end

        assemble_params[:new_private_subnet_name] = ps_name
      elsif (ps = authorized_private_subnet(location_id: @location.id))
        assemble_params[:private_subnet_id] = ps.id
      else
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{ps_id}\" is not found in the location \"#{@location.ui_name}\""})
      end
    end
    assemble_params[:unix_user] ||= "lr"

    requested_vm_vcpu_count = parsed_size.nil? ? 2 : parsed_size.vcpus
    Validation.validate_vcpu_quota(project, "VmVCpu", requested_vm_vcpu_count)

    vm = nil
    DB.transaction do
      vm = Prog::Vm::Nexus.assemble(
        public_key,
        project.id,
        name:,
        location_id: @location.id,
        **assemble_params,
      ).subject
      audit_log(vm, "create")
    end

    if api?
      Serializers::Vm.serialize(vm, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect vm
    end
  end

  def generate_vm_options
    options = OptionTreeGenerator.new

    linode_gpu_enabled = Config.compute_provider == "linode"
    @show_gpu = typecast_params.bool("show_gpu")
    @show_gpu = false unless @project.get_ff_gpu_vm || linode_gpu_enabled
    @show_gpu = false if linode_gpu_enabled && @show_gpu.nil?
    # @show_gpu:
    # true: Only show options valid for GPU configurations
    # false: Do not show GPU options
    # nil: Show GPU options, but also show options not valid for GPU configurations

    if @show_gpu != false
      ff_visible_locations = @project.get_ff_visible_locations || []
      available_gpus = DB[:pci_device]
        .join(:vm_host, id: :vm_host_id)
        .join(:location, id: :location_id)
        .where(device_class: ["0300", "0302"], vm_id: nil)
        .where(Sequel.|([:visible], name: ff_visible_locations))
        .group_and_count(:vm_host_id, :name, :device)
        .from_self
        .select_group { [name.as(:location_name), device] }
        .select_append { max(:count).as(:max_count) }
        .all.filter { !!BillingRate.from_resource_properties("Gpu", it[:device], it[:location_name]) }

      if Config.compute_provider == "linode"
        linode_gpu_locations = Option.locations(feature_flags: @project.feature_flags)
          .select { it.linode? && Option.linode_gpu_location?(it.name) }
          .map(&:name)
        available_gpus.concat(
          linode_gpu_locations.map {
            {location_name: it, device: Option::LINODE_GPU_DEVICE, max_count: 1}
          },
        )
      end

      gpu_counts = (Config.compute_provider == "linode") ? [1] : [1, 2, 4, 8]
      gpu_options = available_gpus.map { it[:device] }.uniq.flat_map { |x| gpu_counts.map { |i| "#{i}:#{x}" } }
      gpu_availability = available_gpus.each_with_object({}) do |entry, hash|
        hash[entry[:location_name]] ||= {}
        hash[entry[:location_name]][entry[:device]] = entry[:max_count]
      end
      gpu_locations = gpu_availability.keys

      if @show_gpu
        if gpu_locations.empty? && web?
          flash["error"] = "Unfortunately, no virtual machines with GPUs are currently available."
          request.redirect @project, "/vm/create"
        end

        location_family_check = lambda do |location, family|
          !gpu_locations.include?(location.name) || family == "burstable"
        end
      end
    end

    options.add_option(name: "name")
    locations = Option.locations(feature_flags: @project.feature_flags)
    locations = locations.select { it.provider == Config.compute_provider } if Config.compute_provider

    options.add_option(name: "location", values: locations) do |location|
      !@show_gpu || gpu_locations.include?(location.name)
    end

    subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").map {
      {
        location_id: it.location_id,
        value: it.ubid,
        display_name: it.name,
      }
    }
    locations.each do |location|
      subnets << {
        location_id: location.id,
        value: "new-#{location.ubid}",
        display_name: "New Private Subnet",
      }
    end
    options.add_option(name: "private_subnet_id", values: subnets, parent: "location") do |location, private_subnet|
      private_subnet[:location_id] == location.id
    end

    options.add_option(name: "enable_ip4", values: ["1"], parent: "location")

    options.add_option(name: "family", values: Option.families.map(&:name), parent: "location") do |location, family|
      next false if location_family_check&.call(location, family)

      !!BillingRate.from_resource_properties("VmVCpu", family, location.name)
    end

    options.add_option(name: "size", values: Option::VmSizes.select(&:visible).map(&:display_name), parent: "family") do |location, family, size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      next false unless vm_size.family == family
      if location.linode?
        begin
          if @show_gpu
            Option.linode_instance_type_name(family, vm_size.vcpus, gpu_count: 1, gpu_device: Option::LINODE_GPU_DEVICE, size_name: vm_size.display_name)
          else
            Option.linode_instance_type_name(family, vm_size.vcpus, size_name: vm_size.display_name)
          end
          true
        rescue Validation::ValidationFailed
          false
        end
      else
        true
      end
    end

    options.add_option(name: "storage_size", values: ["10", "20", "25", "40", "50", "80", "160", "320", "512", "600", "640", "1200", "2400"], parent: "size") do |location, family, size, storage_size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      if location.linode?
        begin
          plan = if @show_gpu
            Option.linode_plan(family, vm_size.vcpus, gpu_count: 1, gpu_device: Option::LINODE_GPU_DEVICE, size_name: vm_size.display_name)
          else
            Option.linode_plan(family, vm_size.vcpus, size_name: vm_size.display_name)
          end
          plan.disk_gib == storage_size.to_i
        rescue Validation::ValidationFailed
          false
        end
      else
        vm_size.storage_size_options.include?(storage_size.to_i)
      end
    end

    if @show_gpu != false
      base_gpu_options = @show_gpu ? [] : ["0:"]
      options.add_option(name: "gpu", values: base_gpu_options + gpu_options, parent: "family") do |location, family, gpu|
        gpu_count, device = gpu.split(":", 2)
        gpu_count = gpu_count.to_i
        device_availability = gpu_availability.dig(location.name, device)
        next true if gpu_count == 0

        family == "standard" &&
          !!BillingRate.from_resource_properties("Gpu", device, location.name) &&
          device_availability &&
          device_availability >= gpu_count
      end
    end

    boot_images = if @show_gpu && Config.compute_provider == "linode"
      ["gpu-ubuntu-noble"]
    else
      Option::BootImages.map(&:name).tap do |images|
        images.reject! { |name| name == "gpu-ubuntu-noble" } unless @show_gpu != false
      end
    end
    boot_images.select! { Option.linode_boot_image?(it) } if locations.any?(&:linode?)
    options.add_option(name: "boot_image", values: boot_images)
    options.add_option(name: "unix_user")
    options.add_option(name: "ssh_public_key", values: @project.ssh_public_keys)
    options.add_option(name: "public_key")
    options.add_option(name: "init_script")

    options.serialize
  end
end
