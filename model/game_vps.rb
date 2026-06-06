# frozen_string_literal: true

require_relative "../model"

class GameVps < Sequel::Model(:game_vps)
  STATUSES = %w[creating running failed deleting deleted].freeze
  LOCATIONS = {
    "de/fra" => {name: "Frankfurt, DE", region: "Europe"},
    "gb/lhr" => {name: "London, UK", region: "Europe"},
    "us/las" => {name: "Las Vegas, US", region: "United States"},
    "us/ewr" => {name: "Newark, US", region: "United States"},
  }.freeze
  PLANS = {
    "starter" => {
      name: "Starter",
      description: "Entry Windows VPS",
      cores: 2,
      ram_gib: 4,
      disk_gib: 80,
      monthly_price: "4.99",
    },
    "community" => {
      name: "Community",
      description: "Growing FiveM server",
      cores: 4,
      ram_gib: 8,
      disk_gib: 160,
      monthly_price: "8.99",
    },
    "growth" => {
      name: "Growth",
      description: "Busy game community",
      cores: 8,
      ram_gib: 16,
      disk_gib: 320,
      monthly_price: "14.99",
    },
    "serious" => {
      name: "Serious",
      description: "High-capacity roleplay",
      cores: 16,
      ram_gib: 32,
      disk_gib: 640,
      monthly_price: "29.99",
    },
  }.freeze

  one_to_one :strand, key: :id
  many_to_one :project, read_only: true
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active

  plugin ResourceMethods, encrypted_columns: [:rdp_password, :txadmin_password]
  plugin SemaphoreMethods, :destroy

  dataset_module Pagination

  def self.locations
    LOCATIONS
  end

  def self.plans
    PLANS
  end

  def self.price_label(plan)
    "$#{format("%0.2f", plan[:monthly_price].to_f)}/mo"
  end

  def location_label
    LOCATIONS.dig(location, :name) || location
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
