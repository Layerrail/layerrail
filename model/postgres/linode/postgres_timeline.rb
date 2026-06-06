# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Linode
    private

    def linode_generate_walg_config(version)
      metal_generate_walg_config(version)
    end

    def linode_walg_config_region
      metal_walg_config_region
    end

    def linode_blob_storage
      metal_blob_storage
    end

    def linode_blob_storage_client
      metal_blob_storage_client
    end

    def linode_list_objects(prefix, delimiter: "")
      metal_list_objects(prefix, delimiter:)
    end

    def linode_create_bucket
      metal_create_bucket
    end

    def linode_set_lifecycle_policy
      metal_set_lifecycle_policy
    end

    def linode_destroy_blob_storage
      metal_destroy_blob_storage
    end

    def linode_setup_blob_storage
      metal_setup_blob_storage
    end

    def linode_generate_blob_storage_credentials?
      metal_generate_blob_storage_credentials?
    end
  end
end

# Table: postgres_timeline
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                 | uuid                     |
#  access_key                | text                     |
#  secret_key                | text                     |
#  latest_backup_started_at  | timestamp with time zone |
#  location_id               | uuid                     |
#  cached_earliest_backup_at | timestamp with time zone |
#  backup_period_hours       | smallint                 | NOT NULL DEFAULT 24
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_timeline_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
