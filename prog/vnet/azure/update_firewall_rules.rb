# frozen_string_literal: true

class Prog::Vnet::Azure::UpdateFirewallRules < Prog::Base
  subject_is :vm

  label def update_firewall_rules
    vm.private_subnets.each(&:incr_update_firewall_rules)
    pop "firewall rule is added"
  end
end
