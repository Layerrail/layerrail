# frozen_string_literal: true

class Prog::Vnet::Azure::SubnetNexus < Prog::Base
  subject_is :private_subnet

  label def start
    private_subnet.update(state: "waiting") unless private_subnet.state == "waiting"
    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      decr_update_firewall_rules
    end
    nap 6 * 60 * 60
  end

  label def destroy
    decr_destroy
    delete_resource_group
    private_subnet.destroy
    pop "subnet deleted"
  end

  private

  def delete_resource_group
    AzureClient.new.delete_resource_group(azure_subnet_name("rg", 80))
  rescue AzureAPIError => ex
    raise unless ex.status == 404
  end

  def azure_subnet_name(prefix, max_length)
    "lr-#{prefix}-#{private_subnet.ubid}".downcase.gsub(/[^a-z0-9-]/, "-")[0, max_length].delete_suffix("-")
  end
end
