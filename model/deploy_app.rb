# frozen_string_literal: true

require_relative "../model"

class DeployApp < Sequel::Model(:deploy_app)
  STATUSES = %w[idle provisioning deploying live failed deleting].freeze
  FRAMEWORKS = {
    "node" => "Node.js",
    "static" => "Static site",
  }.freeze

  one_to_one :strand, key: :id
  many_to_one :project, read_only: true
  many_to_one :installation, class: :GithubInstallation, key: :installation_id, read_only: true
  many_to_one :vm, read_only: true
  many_to_one :location, read_only: true
  one_to_many :deployments, key: :app_id, class: :DeployDeployment, order: Sequel.desc(:created_at), remover: nil, clearer: nil
  one_to_many :variables, key: :app_id, class: :DeployVariable, order: :key, remover: nil, clearer: nil

  plugin :association_dependencies, deployments: :destroy, variables: :destroy
  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
  dataset_module Pagination

  def self.vm_size_options
    Option::VmSizes
      .select { it.visible && it.arch == "x64" && %w[nanode burstable standard].include?(it.family) }
      .map { [it.name, "#{it.name} (#{it.vcpus} vCPU / #{it.memory_gib} GB)"] }
      .uniq(&:first)
  end

  def display_state
    return "deleting" if destroy_set? || destroying_set?

    status
  end

  def path
    "/deploy/#{ubid}"
  end

  def public_hostname
    hostname || "#{name}-#{ubid.to_s[2, 6]}.#{Config.deploy_service_hostname}"
  end

  def public_url
    "https://#{public_hostname}"
  end

  def repository_url
    "https://github.com/#{repository}"
  end

  def framework_label
    FRAMEWORKS.fetch(framework, framework)
  end

  def latest_deployment
    deployments.first
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_includes(FRAMEWORKS.keys, :framework)
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers and hyphens, and must start and end with a lowercase letter or number")
    validates_format(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}, :repository, message: "must be in owner/repository format")
    errors.add(:app_port, "must be between 1 and 65535") unless app_port && app_port.between?(1, 65_535)
    errors.add(:root_directory, "must be relative") if root_directory.to_s.start_with?("/")
    errors.add(:output_directory, "must be relative") if output_directory.to_s.start_with?("/")
    Validation.validate_vm_size(vm_size, "x64", only_visible: true)
  rescue Validation::ValidationFailed => ex
    ex.details.each { |key, message| errors.add(key, message) }
  end
end
