# frozen_string_literal: true

require "bigdecimal"
require "json"
require_relative "../model"

class GameVps < Sequel::Model(:game_vps)
  STATUSES = %w[pending_payment creating running failed deleting deleted].freeze
  AZURE_LOCATIONS = {
    "azure-eastus" => {name: "East US", region: "United States", azure_region: "eastus"},
    "azure-eastus2" => {name: "East US 2", region: "United States", azure_region: "eastus2"},
    "azure-westeurope" => {name: "West Europe", region: "Europe", azure_region: "westeurope"},
    "azure-northeurope" => {name: "North Europe", region: "Europe", azure_region: "northeurope"},
  }.freeze
  IONOS_LOCATIONS = {
    "de/fra" => {name: "Frankfurt, DE", region: "Europe"},
    "gb/lhr" => {name: "London, UK", region: "Europe"},
    "us/las" => {name: "Las Vegas, US", region: "United States"},
    "us/ewr" => {name: "Newark, US", region: "United States"},
  }.freeze
  LOCATIONS = AZURE_LOCATIONS.merge(IONOS_LOCATIONS).freeze
  PLANS = {
    "starter" => {
      name: "Starter Windows",
      description: "Small Windows server for testing and private sessions",
      cores: 2,
      ram_gib: 4,
      disk_gib: 128,
      azure_size: "Standard_D2lds_v7",
      monthly_price: "4.00",
    },
    "community" => {
      name: "Community",
      description: "Entry community server for FiveM or Minecraft",
      cores: 4,
      ram_gib: 8,
      disk_gib: 160,
      azure_size: "Standard_D4lds_v7",
      monthly_price: "6.00",
    },
    "squad" => {
      name: "Squad",
      description: "More memory for mods, plugins, and voice",
      cores: 2,
      ram_gib: 8,
      disk_gib: 160,
      azure_size: "Standard_D2ds_v7",
      monthly_price: "10.00",
    },
    "growth" => {
      name: "Growth",
      description: "Growing roleplay or survival community",
      cores: 4,
      ram_gib: 16,
      disk_gib: 256,
      azure_size: "Standard_D4ds_v7",
      monthly_price: "20.00",
    },
    "serious" => {
      name: "Serious",
      description: "Busy game community with heavier workloads",
      cores: 8,
      ram_gib: 32,
      disk_gib: 512,
      azure_size: "Standard_D8ds_v7",
      monthly_price: "50.00",
    },
    "arena" => {
      name: "Arena",
      description: "Large community server with room to scale",
      cores: 16,
      ram_gib: 64,
      disk_gib: 1024,
      azure_size: "Standard_D16ds_v7",
      monthly_price: "95.00",
    },
  }.freeze
  WINDOWS_IMAGES = {
    "windows-11-pro" => {
      name: "Windows 11 Pro",
      description: "Desktop gaming tools",
      azure_image: {publisher: "MicrosoftWindowsDesktop", offer: "windows-11", sku: "win11-25h2-pro", version: "latest"},
    },
    "windows-server-2022" => {
      name: "Windows Server 2022",
      description: "Recommended",
      azure_image: {publisher: "MicrosoftWindowsServer", offer: "WindowsServer", sku: "2022-datacenter", version: "latest"},
    },
    "windows-server-2022-azure" => {
      name: "Windows Server 2022 LayerRail Edition",
      description: "LayerRail optimized",
      azure_image: {publisher: "MicrosoftWindowsServer", offer: "WindowsServer", sku: "2022-datacenter-azure-edition", version: "latest"},
    },
    "windows-server-2019" => {
      name: "Windows Server 2019",
      description: "Legacy compatible",
      azure_image: {publisher: "MicrosoftWindowsServer", offer: "WindowsServer", sku: "2019-datacenter", version: "latest"},
    },
  }.freeze

  one_to_one :strand, key: :id
  many_to_one :project, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, encrypted_columns: [:rdp_password, :txadmin_password]
  plugin SemaphoreMethods, :destroy

  dataset_module Pagination

  def self.locations(provider: Config.game_vps_provider)
    provider == "ionos" ? IONOS_LOCATIONS : AZURE_LOCATIONS
  end

  def self.plans
    PLANS
  end

  def self.windows_images
    WINDOWS_IMAGES
  end

  def self.azure_image_reference(image_alias)
    WINDOWS_IMAGES.fetch(image_alias).fetch(:azure_image).transform_keys(&:to_s)
  rescue KeyError
    raise Validation::ValidationFailed.new({image_alias: "#{image_alias} is not available for Azure Game VPS"})
  end

  def self.price_label(plan)
    "$#{format("%0.2f", plan[:monthly_price].to_f)}/mo"
  end

  def self.amount_cents(plan)
    (BigDecimal(plan.fetch(:monthly_price)) * 100).to_i
  end

  def self.polar_product_ids
    raw = Config.polar_game_vps_product_ids.to_s.strip
    return {} if raw.empty?

    JSON.parse(raw)
  rescue JSON::ParserError
    raise "POLAR_GAME_VPS_PRODUCT_IDS must be a JSON object keyed by Game VPS plan"
  end

  def self.polar_product_id_for(plan_key)
    product_id = polar_product_ids[plan_key.to_s] || Config.polar_game_vps_product_id
    raise "Set POLAR_GAME_VPS_PRODUCT_IDS with a product id for #{plan_key}." unless product_id

    product_id
  end

  def location_label
    LOCATIONS.dig(location, :name) || location
  end

  def provider_label
    (provider || Config.game_vps_provider).to_s == "ionos" ? "IONOS" : "LayerRail"
  end

  def plan_label
    PLANS.dig(plan, :name) || plan
  end

  def plan_description
    PLANS.dig(plan, :description)
  end

  def resources_label
    "#{cores} vCPU / #{ram_gib} GB RAM / #{disk_gib} GB SSD"
  end

  def price_label
    "$#{format("%0.2f", monthly_price.to_f)}/mo"
  end

  def amount_cents
    subscription_amount_cents || (BigDecimal(monthly_price.to_s) * 100).to_i
  end

  def polar_product_id
    self.class.polar_product_id_for(plan)
  end

  def prepaid?
    !!checkout_id
  end

  def display_state
    return "deleting" if destroy_set? || destroying_set?

    status
  end

  def path
    "/game-vps/#{ubid}"
  end

  def validate
    super
    validates_includes(STATUSES, :status)
    validates_includes(LOCATIONS.keys, :location)
    validates_includes(PLANS.keys, :plan)
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers and hyphens, and must start and end with a lowercase letter or number")
  end
end

# Table: game_vps
# Columns:
#  id                 | uuid                     | PRIMARY KEY
#  project_id         | uuid                     | NOT NULL
#  name               | text                     | NOT NULL
#  provider           | text                     | NOT NULL DEFAULT 'ionos'::text
#  status             | text                     | NOT NULL DEFAULT 'creating'::text
#  plan               | text                     | NOT NULL
#  location           | text                     | NOT NULL
#  image_alias        | text                     | NOT NULL
#  datacenter_id      | text                     |
#  server_id          | text                     |
#  lan_id             | text                     |
#  nic_id             | text                     |
#  volume_id          | text                     |
#  request_status_url | text                     |
#  primary_ip         | text                     |
#  rdp_username       | text                     | NOT NULL DEFAULT 'Administrator'::text
#  rdp_password       | text                     |
#  txadmin_password   | text                     |
#  failure_message    | text                     |
#  access_notes       | text                     |
#  cores              | integer                  | NOT NULL
#  ram_gib            | integer                  | NOT NULL
#  disk_gib           | integer                  | NOT NULL
#  monthly_price      | numeric                  | NOT NULL
#  created_at         | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at         | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  game_vps_pkey                  | PRIMARY KEY btree (id)
#  game_vps_project_id_name_index | UNIQUE btree (project_id, name)
#  game_vps_project_id_index      | btree (project_id)
# Check constraints:
#  valid_game_vps_status | (status = ANY (ARRAY['creating'::text, 'running'::text, 'failed'::text, 'deleting'::text, 'deleted'::text]))
# Foreign key constraints:
#  game_vps_project_id_fkey | (project_id) REFERENCES project(id)
