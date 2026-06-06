# frozen_string_literal: true

require_relative "../model"

class LinodeInstance < Sequel::Model
  many_to_one :vm, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_VM
end

# Table: linode_instance
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  linode_id   | integer                  | NOT NULL
#  region      | text                     | NOT NULL
#  linode_type | text                     | NOT NULL
#  image       | text                     | NOT NULL
#  label       | text                     | NOT NULL
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  linode_instance_pkey          | PRIMARY KEY btree (id)
#  linode_instance_linode_id_key | UNIQUE btree (linode_id)
# Foreign key constraints:
#  linode_instance_id_fkey | (id) REFERENCES vm(id) ON DELETE CASCADE
