# frozen_string_literal: true

class Prog::Deploy::AppNexus < Prog::Base
  subject_is :deploy_app

  def self.assemble_destroy(deploy_app)
    if deploy_app.strand
      deploy_app.incr_destroy
    else
      Strand.create_with_id(deploy_app, prog: "Deploy::AppNexus", label: "destroy")
    end
  end

  def before_destroy
    register_deadline(nil, 10 * 60)
  end

  label def destroy
    decr_destroy
    deploy_app.update(status: "deleting", updated_at: Time.now) unless deploy_app.status == "deleting"

    deploy_app.vm&.incr_destroy
    hop_wait_vm_destroy if deploy_app.vm

    destroy_app
  end

  label def wait_vm_destroy
    nap 10 if deploy_app.reload.vm

    destroy_app
  end

  private

  def destroy_app
    delete_dns_record
    deploy_app.destroy
    pop "deploy app destroyed"
  end

  def delete_dns_record
    deploy_app.project.domain_registrations_dataset.where(deploy_app_id: deploy_app.id).each(&:clear_deploy_dns_record!)
    return unless Config.deploy_service_project_id && Config.deploy_service_hostname
    return unless deploy_app.public_hostname.end_with?(".#{Config.deploy_service_hostname}")

    DnsZone.ensure_service_zone(project_id: Config.deploy_service_project_id, name: Config.deploy_service_hostname)
      &.delete_record(record_name: deploy_app.public_hostname)
  end
end
