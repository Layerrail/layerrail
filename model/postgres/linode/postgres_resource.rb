# frozen_string_literal: true

class PostgresResource < Sequel::Model
  module Linode
    private

    def linode_boot_image(_pg_version, _arch)
      "postgres-ubuntu-2204"
    end

    def linode_upgrade_candidate_server
      nil
    end

    def linode_lockout_mechanisms
      ["pg_stop", "hba"].freeze
    end

    def linode_new_server_exclusion_filters
      ServerExclusionFilters.new(exclude_host_ids: [], exclude_data_centers: [], exclude_availability_zones: [], availability_zone: nil)
    end
  end
end

