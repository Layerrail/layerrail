# frozen_string_literal: true

require_relative "../model"

class LinodeStorageVolume < Sequel::Model
  many_to_one :vm_storage_volume, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_VM_STORAGE_VOLUME
end

# Table: linode_storage_volume
# Columns:
#  id              | uuid                     | PRIMARY KEY
#  volume_id       | integer                  | NOT NULL
#  label           | text                     | NOT NULL
#  filesystem_path | text                     | NOT NULL
#  created_at      | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  linode_storage_volume_pkey          | PRIMARY KEY btree (id)
#  linode_storage_volume_label_key     | UNIQUE btree (label)
#  linode_storage_volume_volume_id_key | UNIQUE btree (volume_id)
# Foreign key constraints:
#  linode_storage_volume_id_fkey | (id) REFERENCES vm_storage_volume(id) ON DELETE CASCADE
