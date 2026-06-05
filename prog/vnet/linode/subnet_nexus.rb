# frozen_string_literal: true

class Prog::Vnet::Linode::SubnetNexus < Prog::Base
  subject_is :private_subnet

  label def start
    register_deadline("wait", 5 * 60)
    unless private_subnet.private_subnet_linode_resource
      firewall = create_linode_firewall
      PrivateSubnetLinodeResource.create_with_id(private_subnet, firewall_id: firewall.fetch("id"))
    end

    private_subnet.update(state: "waiting")
    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      hop_update_firewall_rules
    end

    when_destroy_set? do
      hop_destroy
    end

    nap 6 * 60 * 60
  end

  label def update_firewall_rules
    decr_update_firewall_rules
    if (resource = private_subnet.private_subnet_linode_resource)
      begin
        client.update_firewall_rules(resource.firewall_id, linode_firewall_rules)
      rescue LinodeAPIError => ex
        raise unless ex.status == 404

        firewall = create_linode_firewall
        resource.update(firewall_id: firewall.fetch("id"))
      end
    end
    hop_wait
  end

  label def destroy
    decr_destroy

    if private_subnet.nics.any?(&:vm_id)
      Clog.emit("Cannot destroy subnet with active nics, first clean up the attached resources", private_subnet)
      nap 5
    end

    private_subnet.nics.each(&:incr_destroy)
    private_subnet.load_balancers.each(&:incr_destroy)
    private_subnet.remove_all_firewalls

    resource = private_subnet.private_subnet_linode_resource
    client.delete_firewall(resource.firewall_id) if resource&.firewall_id
    resource&.destroy

    nap 1 unless private_subnet.nics.empty? && private_subnet.load_balancers.empty?
    private_subnet.destroy
    pop "private subnet deleted"
  end

  private

  def client
    @client ||= LinodeClient.new
  end

  def create_linode_firewall
    client.create_firewall(
      label: "lr-#{private_subnet.ubid[0, 20]}",
      rules: linode_firewall_rules,
      tags: ["LayerRail", private_subnet.project.ubid],
    )
  end

  def linode_firewall_rules
    firewall_rules = private_subnet.firewalls(eager: :firewall_rules).flat_map(&:firewall_rules)
    firewall_rules += private_subnet.attached_vms.flat_map do |vm|
      vm.vm_firewalls_dataset.eager(:firewall_rules).all.flat_map(&:firewall_rules)
    end
    firewall_rules.uniq!(&:id)

    {
      "inbound_policy" => "DROP",
      "outbound_policy" => "ACCEPT",
      "inbound" => firewall_rules.map { linode_rule(it) } + control_plane_ssh_rules(firewall_rules),
      "outbound" => [],
    }
  end

  def control_plane_ssh_rules(firewall_rules)
    existing_ssh_cidrs = firewall_rules
      .select { ssh_allowed_by_rule?(it) }
      .map { it.cidr.to_s }

    Config.control_plane_outbound_cidrs.reject { existing_ssh_cidrs.include?(it) }.each_with_index.map do |cidr, index|
      addresses = {"ipv4" => [], "ipv6" => []}
      addresses[cidr.include?(":") ? "ipv6" : "ipv4"] = [cidr]
      {
        "action" => "ACCEPT",
        "protocol" => "TCP",
        "ports" => "22",
        "addresses" => addresses,
        "label" => "lr-control-plane-ssh-#{index}",
      }
    end
  end

  def ssh_allowed_by_rule?(rule)
    return false unless rule.protocol == "tcp"

    range = rule.port_range&.to_range
    range.nil? || range.cover?(22)
  end

  def linode_rule(rule)
    cidr = rule.cidr.to_s
    addresses = {"ipv4" => [], "ipv6" => []}
    addresses[rule.ip6? ? "ipv6" : "ipv4"] = [cidr]
    {
      "action" => "ACCEPT",
      "protocol" => rule.protocol.upcase,
      "ports" => linode_ports(rule.port_range),
      "addresses" => addresses,
      "label" => "lr-#{rule.ubid[0, 20]}",
    }
  end

  def linode_ports(range)
    return "1-65535" unless range

    first = [range.begin, 1].max
    last = range.exclude_end? ? range.end - 1 : range.end
    last = [last, 65535].min
    first == last ? first.to_s : "#{first}-#{last}"
  end
end
