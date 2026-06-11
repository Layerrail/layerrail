# frozen_string_literal: true

class Vm < Sequel::Model
  module Azure
    private

    def azure_ip6
      ephemeral_net6&.nth(0)
    end

    def azure_update_firewall_rules_prog
      Prog::Vnet::Azure::UpdateFirewallRules
    end

    def azure_validate_firewall_cap(firewall)
      nil
    end

    def azure_validate_subnet_firewall_cap(subnet)
      nil
    end
  end
end
