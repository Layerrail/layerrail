# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Linode
    private

    def linode_connect_subnet(subnet)
      raise "Connected subnets are not supported for Linode"
    end

    def linode_disconnect_subnet(subnet)
      raise "Connected subnets are not supported for Linode"
    end

    def linode_apply_firewalls
      incr_update_firewall_rules
    end

    def linode_validate_firewall_attachment(firewall)
      # Linode Cloud Firewalls do not have LayerRail-side attachment caps.
      nil
    end

    def linode_ipv4_reservation
      [4, 1]
    end
  end
end

