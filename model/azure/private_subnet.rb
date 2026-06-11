# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Azure
    private

    def azure_connect_subnet(subnet)
      raise "Connected subnets are not supported for Azure"
    end

    def azure_disconnect_subnet(subnet)
      raise "Connected subnets are not supported for Azure"
    end

    def azure_apply_firewalls
      incr_update_firewall_rules
    end

    def azure_validate_firewall_attachment(firewall)
      nil
    end

    def azure_ipv4_reservation
      [4, 1]
    end
  end
end
