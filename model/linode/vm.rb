# frozen_string_literal: true

class Vm < Sequel::Model
  module Linode
    private

    def linode_ip6
      ephemeral_net6&.nth(0)
    end

    def linode_update_firewall_rules_prog
      Prog::Vnet::Linode::UpdateFirewallRules
    end

    def linode_validate_firewall_cap(firewall)
      # Linode Cloud Firewalls are synced through the subnet firewall.
      nil
    end

    def linode_validate_subnet_firewall_cap(subnet)
      # Linode Cloud Firewalls are synced through the subnet firewall.
      nil
    end
  end
end

