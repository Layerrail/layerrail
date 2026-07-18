# frozen_string_literal: true

class UsageLimitEnforcer
  RESOURCE_DATASET_METHODS = (Project::RESOURCE_ASSOCIATION_DATASET_METHODS + %i[inference_endpoints_dataset api_keys_dataset]).uniq.freeze
  NON_RUNNING_VM_LABELS = %w[stopped stopped_by_admin destroy].freeze

  def self.suspend!(usage_limit, only_if_suspended: false)
    new(usage_limit).suspend!(only_if_suspended:)
  end

  def self.resume!(usage_limit)
    new(usage_limit).resume!
  end

  def initialize(usage_limit)
    @usage_limit = usage_limit
    @project = usage_limit.project
  end

  def suspend!(only_if_suspended: false)
    DB.transaction do
      usage_limit.lock!
      return false if only_if_suspended && !usage_limit.suspended?

      snapshot_active_billing_records
      suspend_vms
      suspend_game_vpses
      suspend_object_buckets
      suspend_edge_services

      unless usage_limit.suspended?
        usage_limit.update(suspended_at: Time.now, suspended_revision: usage_limit.revision)
      end
    end
  end

  def resume!
    DB.transaction do
      usage_limit.lock!
      snapshot_active_billing_records
      restore_billing_records
      resume_vms
      resume_game_vpses
      resume_object_buckets
      resume_edge_services
    end
  end

  private

  attr_reader :usage_limit, :project

  def snapshot_active_billing_records
    BillingRecord.where(project_id: project.id).active.for_update.each do |record|
      next if record.billing_rate["billed_by"] == "amount"

      UsageLimitBillingRecord.dataset.insert_conflict.insert(
        usage_limit_id: usage_limit.id,
        billing_record_id: record.id,
        project_id: record.project_id,
        resource_id: record.resource_id,
        resource_name: record.resource_name,
        amount: record.amount,
        billing_rate_id: record.billing_rate_id,
        resource_tags: record.resource_tags || Sequel.pg_jsonb_wrap({}),
        snapshotted_at: Time.now,
      )
      record.finalize
    end
  end

  def restore_billing_records
    UsageLimitBillingRecord.where(usage_limit_id: usage_limit.id).reverse(:snapshotted_at).each do |snapshot|
      unless resource_exists?(snapshot)
        Clog.emit("Skipped restoring usage-limit billing for a deleted resource", {usage_limit_id: usage_limit.id, project_id: project.id, resource_id: snapshot.resource_id, billing_record_id: snapshot.billing_record_id})
        next
      end

      existing = BillingRecord.where(
        project_id: snapshot.project_id,
        resource_id: snapshot.resource_id,
        resource_name: snapshot.resource_name,
        billing_rate_id: snapshot.billing_rate_id,
      ).active.first
      next if existing

      BillingRecord.create(
        project_id: snapshot.project_id,
        resource_id: snapshot.resource_id,
        resource_name: snapshot.resource_name,
        amount: snapshot.amount,
        billing_rate_id: snapshot.billing_rate_id,
        resource_tags: snapshot.resource_tags || Sequel.pg_jsonb_wrap({}),
      )
    end

    UsageLimitBillingRecord.where(usage_limit_id: usage_limit.id).destroy
  end

  def resource_exists?(snapshot)
    resource_id = snapshot.resource_id
    RESOURCE_DATASET_METHODS.any? do |dataset_method|
      project.public_send(dataset_method).where(id: resource_id).any?
    end || vm_backup_resource_exists?(snapshot) || machine_image_resource_exists?(resource_id)
  end

  def vm_backup_resource_exists?(snapshot)
    vm_id = snapshot.resource_tags["vm_id"]
    vm_id && project.vms_dataset.where(id: vm_id).any?
  end

  def machine_image_resource_exists?(resource_id)
    MachineImageVersion
      .association_join(:machine_image)
      .where(Sequel[:machine_image_version][:id] => resource_id, Sequel[:machine_image][:project_id] => project.id)
      .any?
  end

  def suspend_vms
    project.vms_dataset.eager(:strand, :semaphores).all.each do |vm|
      next if vm.destroy_set? || vm.destroying_set? || vm.admin_stop_set?
      next if NON_RUNNING_VM_LABELS.include?(vm.strand&.label)
      next if vm.usage_limit_suspended_set?

      vm.incr_usage_limit_suspended
      vm.incr_stop unless vm.stop_set?
    end
  end

  def resume_vms
    project.vms_dataset.eager(:strand, :semaphores).all.each do |vm|
      next unless vm.usage_limit_suspended_set?

      vm.decr_usage_limit_suspended
      vm.incr_start unless vm.start_set?
    end
  end

  def suspend_game_vpses
    project.game_vpses_dataset.eager(:strand, :semaphores).exclude(status: %w[pending_payment failed deleting deleted]).all.each do |game_vps|
      next unless game_vps.strand
      next if game_vps.usage_limit_suspended_set?

      game_vps.incr_usage_limit_suspended
    end
  end

  def resume_game_vpses
    project.game_vpses_dataset.eager(:strand, :semaphores).all.each do |game_vps|
      next unless game_vps.usage_limit_suspended_set?

      game_vps.decr_usage_limit_suspended
      game_vps.incr_usage_limit_resume unless game_vps.usage_limit_resume_set?
    end
  end

  def suspend_object_buckets
    project.object_buckets_dataset.eager(:strand, :semaphores).exclude(state: %w[failed deleting]).all.each do |bucket|
      bucket.incr_usage_limit_suspended unless bucket.usage_limit_suspended_set?
    end
  end

  def resume_object_buckets
    project.object_buckets_dataset.eager(:strand, :semaphores).all.each do |bucket|
      next unless bucket.usage_limit_suspended_set?

      bucket.decr_usage_limit_suspended
      bucket.incr_usage_limit_resume unless bucket.usage_limit_resume_set?
    end
  end

  def suspend_edge_services
    project.edge_services_dataset.eager(:strand, :semaphores).exclude(state: %w[failed deleting]).all.each do |edge_service|
      edge_service.incr_usage_limit_suspended unless edge_service.usage_limit_suspended_set?
    end
  end

  def resume_edge_services
    project.edge_services_dataset.eager(:strand, :semaphores).all.each do |edge_service|
      next unless edge_service.usage_limit_suspended_set?

      edge_service.decr_usage_limit_suspended
      edge_service.incr_usage_limit_resume unless edge_service.usage_limit_resume_set?
    end
  end
end