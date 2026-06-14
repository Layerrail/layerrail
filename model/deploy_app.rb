# frozen_string_literal: true

require_relative "../model"
require "set"

class DeployApp < Sequel::Model(:deploy_app)
  STATUSES = %w[idle provisioning deploying live failed deleting].freeze
  ENVIRONMENTS = %w[production preview development].freeze
  AUTO_BUILD_PACK = {
    key: "auto",
    label: "Auto detect",
    description: "Read the repository and choose the closest LayerRail build preset.",
    install_command: "",
    build_command: "",
    start_command: "",
    output_directory: "",
    app_port: 3000
  }.freeze
  BUILD_PACKS = [
    {
      key: "node",
      label: "Node.js",
      description: "Express, Next.js custom servers, Nest, Fastify, and other Node apps.",
      install_command: "npm install",
      build_command: "npm run build",
      start_command: "npm start",
      output_directory: "",
      app_port: 3000
    },
    {
      key: "static",
      label: "Static site",
      description: "Vite, Astro static output, docs, and SPA builds served by Nginx.",
      install_command: "npm install",
      build_command: "npm run build",
      start_command: "",
      output_directory: "dist",
      app_port: 3000
    },
    {
      key: "python",
      label: "Python",
      description: "Flask, FastAPI, Django, and Python web services.",
      install_command: "python3 -m venv .venv && . .venv/bin/activate && pip install -U pip wheel && pip install -r requirements.txt && pip install gunicorn",
      build_command: "",
      start_command: ". .venv/bin/activate && gunicorn app:app --bind 0.0.0.0:$PORT",
      output_directory: "",
      app_port: 8000
    },
    {
      key: "ruby",
      label: "Ruby",
      description: "Rails, Sinatra, Hanami, and Rack services.",
      install_command: "bundle install",
      build_command: "bundle exec rake assets:precompile",
      start_command: "bundle exec puma -b tcp://0.0.0.0:$PORT",
      output_directory: "",
      app_port: 3000
    },
    {
      key: "php",
      label: "PHP",
      description: "Plain PHP apps and Composer projects.",
      install_command: "composer install --no-dev --optimize-autoloader",
      build_command: "",
      start_command: "php -S 0.0.0.0:$PORT -t public",
      output_directory: "",
      app_port: 8000
    },
    {
      key: "laravel",
      label: "Laravel",
      description: "Laravel apps with Composer, cache warmup, and public web root.",
      install_command: "composer install --no-dev --optimize-autoloader",
      build_command: "php artisan config:cache && php artisan route:cache && php artisan view:cache",
      start_command: "php artisan serve --host=0.0.0.0 --port=$PORT",
      output_directory: "",
      app_port: 8000
    },
    {
      key: "rust",
      label: "Rust",
      description: "Axum, Actix, Rocket, and other Cargo services.",
      install_command: "cargo fetch",
      build_command: "cargo build --release",
      start_command: "./target/release/app",
      output_directory: "",
      app_port: 8080
    },
    {
      key: "go",
      label: "Go",
      description: "Go modules and compiled HTTP services.",
      install_command: "go mod download",
      build_command: "go build -o layerrail-app .",
      start_command: "./layerrail-app",
      output_directory: "",
      app_port: 8080
    },
    {
      key: "custom",
      label: "Custom",
      description: "Bring any runtime by editing install, build, and start commands.",
      install_command: "",
      build_command: "",
      start_command: "",
      output_directory: "",
      app_port: 3000
    }
  ].freeze
  IMPORT_BUILD_PACKS = [AUTO_BUILD_PACK, *BUILD_PACKS].freeze
  FRAMEWORKS = BUILD_PACKS.to_h { [it[:key], it[:label]] }.freeze

  one_to_one :strand, key: :id
  many_to_one :project, read_only: true
  many_to_one :installation, class: :GithubInstallation, read_only: true
  many_to_one :vm, read_only: true
  many_to_one :location, read_only: true
  many_to_one :production_app, class: :DeployApp, key: :production_app_id, read_only: true
  one_to_many :preview_apps, key: :production_app_id, class: :DeployApp, order: Sequel.desc(:created_at), remover: nil, clearer: nil
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

  def self.vm_size_available?(name)
    vm_size_options.any? { it.first == name }
  end

  def self.build_pack(key)
    BUILD_PACKS.find { it[:key] == key.to_s }
  end

  def self.detect_framework(files)
    names = files.map { it.to_s.downcase }.to_set
    return "laravel" if names.include?("artisan") && names.include?("composer.json")
    return "php" if names.include?("composer.json") || names.any? { it.end_with?(".php") }
    return "ruby" if names.include?("gemfile") || names.include?("config.ru")
    return "python" if names.include?("requirements.txt") || names.include?("pyproject.toml") || names.include?("manage.py")
    return "rust" if names.include?("cargo.toml")
    return "go" if names.include?("go.mod")
    return "static" if names.include?("index.html") && !names.include?("package.json")
    return "node" if names.include?("package.json") || names.include?("next.config.js") || names.include?("vite.config.js") || names.include?("svelte.config.js")

    "custom"
  end

  def self.apply_build_pack_defaults(params, framework)
    pack = build_pack(framework)
    return params unless pack

    params.merge(
      install_command: params[:install_command].to_s.strip.empty? ? pack[:install_command] : params[:install_command],
      build_command: params[:build_command].to_s.strip.empty? ? pack[:build_command] : params[:build_command],
      start_command: params[:start_command].to_s.strip.empty? ? pack[:start_command] : params[:start_command],
      output_directory: params[:output_directory].to_s.strip.empty? ? pack[:output_directory] : params[:output_directory],
      app_port: params[:app_port].to_i.positive? ? params[:app_port] : pack[:app_port],
      framework:
    )
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

  def latest_live_deployment
    deployments_dataset.where(status: "live").order(Sequel.desc(:created_at)).first
  end

  def preview?
    environment == "preview"
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_includes(ENVIRONMENTS, :environment)
    validates_includes(FRAMEWORKS.keys, :framework)
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers and hyphens, and must start and end with a lowercase letter or number")
    validates_format(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}, :repository, message: "must be in owner/repository format")
    errors.add(:app_port, "must be between 1 and 65535") unless app_port && app_port.between?(1, 65_535)
    errors.add(:root_directory, "must be relative") if root_directory.to_s.start_with?("/")
    errors.add(:output_directory, "must be relative") if output_directory.to_s.start_with?("/")
    errors.add(:vm_size, "is not available for LayerRail Deploy") unless self.class.vm_size_available?(vm_size)
    Validation.validate_vm_size(vm_size, "x64", only_visible: true)
  rescue Validation::ValidationFailed => ex
    ex.details.each { |key, message| errors.add(key, message) }
  end
end

# Table: deploy_app
# Columns:
#  id               | uuid                     | PRIMARY KEY
#  project_id       | uuid                     | NOT NULL
#  installation_id  | uuid                     | NOT NULL
#  vm_id            | uuid                     |
#  location_id      | uuid                     | NOT NULL
#  name             | text                     | NOT NULL
#  repository       | text                     | NOT NULL
#  branch           | text                     | NOT NULL DEFAULT 'main'::text
#  root_directory   | text                     | NOT NULL DEFAULT ''::text
#  install_command  | text                     | NOT NULL DEFAULT 'npm install'::text
#  build_command    | text                     |
#  start_command    | text                     |
#  output_directory | text                     |
#  app_port         | integer                  | NOT NULL DEFAULT 3000
#  status           | text                     | NOT NULL DEFAULT 'idle'::text
#  hostname         | text                     |
#  vm_size          | text                     | NOT NULL DEFAULT 'nanode-1'::text
#  framework        | text                     | NOT NULL DEFAULT 'node'::text
#  failure_message  | text                     |
#  environment      | text                     | NOT NULL DEFAULT 'production'::text
#  production_app_id | uuid                    |
#  preview_key      | text                     |
#  auto_deploy      | boolean                  | NOT NULL DEFAULT true
#  build_cache_enabled | boolean               | NOT NULL DEFAULT true
#  created_at       | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at       | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  deploy_app_pkey                  | PRIMARY KEY btree (id)
#  deploy_app_project_id_name_index | UNIQUE btree (project_id, name)
#  deploy_app_installation_id_index | btree (installation_id)
#  deploy_app_project_id_index      | btree (project_id)
#  deploy_app_vm_id_index           | btree (vm_id)
# Check constraints:
#  valid_deploy_app_port   | (app_port >= 1 AND app_port <= 65535)
#  valid_deploy_app_status | (status = ANY (ARRAY['idle'::text, 'provisioning'::text, 'deploying'::text, 'live'::text, 'failed'::text, 'deleting'::text]))
# Foreign key constraints:
#  deploy_app_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  deploy_app_location_id_fkey     | (location_id) REFERENCES location(id)
#  deploy_app_project_id_fkey      | (project_id) REFERENCES project(id)
#  deploy_app_vm_id_fkey           | (vm_id) REFERENCES vm(id) ON DELETE SET NULL
# Referenced By:
#  deploy_deployment | deploy_deployment_app_id_fkey | (app_id) REFERENCES deploy_app(id)
#  deploy_variable   | deploy_variable_app_id_fkey   | (app_id) REFERENCES deploy_app(id)
