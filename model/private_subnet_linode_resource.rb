# frozen_string_literal: true

require_relative "../model"

class PrivateSubnetLinodeResource < Sequel::Model
  many_to_one :private_subnet, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_PRIVATE_SUBNET
end

# Table: private_subnet_linode_resource
# Columns:
#  id          | uuid    | PRIMARY KEY
#  firewall_id | integer | NOT NULL
# Indexes:
#  private_subnet_linode_resource_pkey            | PRIMARY KEY btree (id)
#  private_subnet_linode_resource_firewall_id_key | UNIQUE btree (firewall_id)
# Foreign key constraints:
#  private_subnet_linode_resource_id_fkey | (id) REFERENCES private_subnet(id) ON DELETE CASCADE
