# frozen_string_literal: true

require "excon"
require "json"
require "uri"

class AzureAPIError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
    super("Azure API request failed with HTTP #{status}: #{body}")
  end
end

class AzureClient
  NETWORK_API = "2023-09-01"
  COMPUTE_API = "2024-03-01"
  RESOURCE_API = "2021-04-01"

  def self.enabled?
    Config.azure_subscription_id && Config.azure_tenant_id && Config.azure_client_id && Config.azure_client_secret
  end

  def initialize(subscription_id: Config.azure_subscription_id, tenant_id: Config.azure_tenant_id,
    client_id: Config.azure_client_id, client_secret: Config.azure_client_secret,
    base_url: Config.azure_arm_base_url)
    raise "AZURE_SUBSCRIPTION_ID is required to provision Azure compute" unless subscription_id
    raise "AZURE_TENANT_ID is required to provision Azure compute" unless tenant_id
    raise "AZURE_CLIENT_ID is required to provision Azure compute" unless client_id
    raise "AZURE_CLIENT_SECRET is required to provision Azure compute" unless client_secret

    @subscription_id = subscription_id
    @tenant_id = tenant_id
    @client_id = client_id
    @client_secret = client_secret
    @connection = Excon.new(base_url.delete_suffix("/"), headers: {"Accept" => "application/json", "Content-Type" => "application/json"})
  end

  def create_resource_group(name:, region:, tags: {})
    request(:put, "/subscriptions/#{@subscription_id}/resourceGroups/#{name}", api_version: RESOURCE_API, body: {location: region, tags:}, expected_status: [200, 201])
  end

  def delete_resource_group(name)
    request(:delete, "/subscriptions/#{@subscription_id}/resourceGroups/#{name}", api_version: RESOURCE_API, expected_status: [200, 202, 204, 404])
  end

  def create_network_security_group(resource_group:, region:, name:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Network/networkSecurityGroups", name), api_version: NETWORK_API, body: {
      location: region,
      tags:,
      properties: {
        securityRules: [
          security_rule("lr-allow-ssh", 100, "Tcp", "22"),
          security_rule("lr-allow-services-tcp", 200, "Tcp", "1-65535"),
          security_rule("lr-allow-services-udp", 210, "Udp", "1-65535"),
        ],
      },
    })
  end

  def create_game_network_security_group(resource_group:, region:, name:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Network/networkSecurityGroups", name), api_version: NETWORK_API, body: {
      location: region,
      tags:,
      properties: {
        securityRules: [
          security_rule("lr-allow-rdp", 100, "Tcp", "3389"),
          security_rule("lr-allow-fivem-tcp", 200, "Tcp", "30120"),
          security_rule("lr-allow-fivem-udp", 210, "Udp", "30120"),
          security_rule("lr-allow-txadmin", 220, "Tcp", "40120"),
          security_rule("lr-allow-minecraft", 230, "Tcp", "25565"),
          security_rule("lr-allow-steam-query-tcp", 240, "Tcp", "27015"),
          security_rule("lr-allow-steam-query-udp", 250, "Udp", "27015"),
        ],
      },
    })
  end

  def create_virtual_network(resource_group:, region:, name:, subnet_name:, address_prefix:, nsg_id:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Network/virtualNetworks", name), api_version: NETWORK_API, body: {
      location: region,
      tags:,
      properties: {
        addressSpace: {addressPrefixes: [address_prefix]},
        subnets: [{
          name: subnet_name,
          properties: {
            addressPrefix: address_prefix,
            networkSecurityGroup: {id: nsg_id},
          },
        }],
      },
    })
  end

  def create_public_ip(resource_group:, region:, name:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Network/publicIPAddresses", name), api_version: NETWORK_API, body: {
      location: region,
      tags:,
      sku: {name: "Standard"},
      properties: {
        publicIPAllocationMethod: "Static",
        publicIPAddressVersion: "IPv4",
      },
    })
  end

  def create_network_interface(resource_group:, region:, name:, subnet_id:, public_ip_id:, private_ip:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Network/networkInterfaces", name), api_version: NETWORK_API, body: {
      location: region,
      tags:,
      properties: {
        ipConfigurations: [{
          name: "ipconfig1",
          properties: {
            privateIPAddress: private_ip,
            privateIPAllocationMethod: "Static",
            subnet: {id: subnet_id},
            publicIPAddress: {id: public_ip_id},
          },
        }],
      },
    })
  end

  def create_virtual_machine(resource_group:, region:, name:, vm_size:, image:, username:, ssh_key:, custom_data:, nic_id:, os_disk_name:, data_disks:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Compute/virtualMachines", name), api_version: COMPUTE_API, body: {
      location: region,
      tags:,
      properties: {
        hardwareProfile: {vmSize: vm_size},
        osProfile: {
          computerName: name,
          adminUsername: username,
          customData: custom_data,
          linuxConfiguration: {
            disablePasswordAuthentication: true,
            ssh: {
              publicKeys: [{path: "/home/#{username}/.ssh/authorized_keys", keyData: ssh_key}],
            },
          },
        },
        storageProfile: {
          imageReference: image,
          osDisk: {
            name: os_disk_name,
            createOption: "FromImage",
            diskSizeGB: data_disks.fetch(:boot_size_gib),
            managedDisk: {storageAccountType: "Premium_LRS"},
          },
          dataDisks: data_disks.fetch(:volumes),
        },
        networkProfile: {
          networkInterfaces: [{id: nic_id, properties: {primary: true}}],
        },
      },
    }, expected_status: [200, 201, 202])
  end

  def create_windows_virtual_machine(resource_group:, region:, name:, computer_name:, vm_size:, image:, username:, password:, nic_id:, os_disk_name:, os_disk_size_gib:, tags: {})
    request(:put, resource_path(resource_group, "Microsoft.Compute/virtualMachines", name), api_version: COMPUTE_API, body: {
      location: region,
      tags:,
      properties: {
        hardwareProfile: {vmSize: vm_size},
        osProfile: {
          computerName: computer_name,
          adminUsername: username,
          adminPassword: password,
          windowsConfiguration: {
            provisionVMAgent: true,
            enableAutomaticUpdates: true,
          },
        },
        storageProfile: {
          imageReference: image,
          osDisk: {
            name: os_disk_name,
            createOption: "FromImage",
            diskSizeGB: os_disk_size_gib,
            managedDisk: {storageAccountType: "Premium_LRS"},
          },
        },
        networkProfile: {
          networkInterfaces: [{id: nic_id, properties: {primary: true}}],
        },
      },
    }, expected_status: [200, 201, 202])
  end

  def get_virtual_machine(resource_group, name)
    request(:get, "#{resource_path(resource_group, "Microsoft.Compute/virtualMachines", name)}?$expand=instanceView", api_version: COMPUTE_API)
  end

  def get_public_ip(resource_group, name)
    request(:get, resource_path(resource_group, "Microsoft.Network/publicIPAddresses", name), api_version: NETWORK_API)
  end

  def power_on_virtual_machine(resource_group, name)
    request(:post, "#{resource_path(resource_group, "Microsoft.Compute/virtualMachines", name)}/start", api_version: COMPUTE_API, expected_status: [200, 202])
  end

  def shutdown_virtual_machine(resource_group, name)
    request(:post, "#{resource_path(resource_group, "Microsoft.Compute/virtualMachines", name)}/deallocate", api_version: COMPUTE_API, expected_status: [200, 202])
  end

  def restart_virtual_machine(resource_group, name)
    request(:post, "#{resource_path(resource_group, "Microsoft.Compute/virtualMachines", name)}/restart", api_version: COMPUTE_API, expected_status: [200, 202])
  end

  def delete_virtual_machine(resource_group, name)
    request(:delete, resource_path(resource_group, "Microsoft.Compute/virtualMachines", name), api_version: COMPUTE_API, expected_status: [200, 202, 204, 404])
  end

  def delete_network_interface(resource_group, name)
    request(:delete, resource_path(resource_group, "Microsoft.Network/networkInterfaces", name), api_version: NETWORK_API, expected_status: [200, 202, 204, 404])
  end

  def delete_public_ip(resource_group, name)
    request(:delete, resource_path(resource_group, "Microsoft.Network/publicIPAddresses", name), api_version: NETWORK_API, expected_status: [200, 202, 204, 404])
  end

  def delete_disk(resource_group, name)
    request(:delete, resource_path(resource_group, "Microsoft.Compute/disks", name), api_version: COMPUTE_API, expected_status: [200, 202, 204, 404])
  end

  def resource_id(resource_group, type, name)
    "/subscriptions/#{@subscription_id}/resourceGroups/#{resource_group}/providers/#{type}/#{name}"
  end

  def subnet_resource_id(resource_group, vnet_name, subnet_name)
    "#{resource_id(resource_group, "Microsoft.Network/virtualNetworks", vnet_name)}/subnets/#{subnet_name}"
  end

  private

  def security_rule(name, priority, protocol, ports)
    {
      name:,
      properties: {
        priority:,
        protocol:,
        access: "Allow",
        direction: "Inbound",
        sourceAddressPrefix: "*",
        sourcePortRange: "*",
        destinationAddressPrefix: "*",
        destinationPortRange: ports,
      },
    }
  end

  def resource_path(resource_group, type, name)
    resource_id(resource_group, type, name)
  end

  def request(method, path, api_version:, body: nil, expected_status: 200)
    sep = path.include?("?") ? "&" : "?"
    response = @connection.public_send(
      method,
      path: "#{path}#{sep}api-version=#{api_version}",
      headers: {"Authorization" => "Bearer #{access_token}"},
      body: body && JSON.generate(body),
      expects: Array(expected_status),
    )
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue Excon::Error => e
    response = e.respond_to?(:response) ? e.response : nil
    raise AzureAPIError.new(response&.status, response&.body)
  end

  def access_token
    return @access_token if @access_token && Time.now < @access_token_expires_at

    response = Excon.post(
      "https://login.microsoftonline.com/#{@tenant_id}/oauth2/v2.0/token",
      headers: {"Content-Type" => "application/x-www-form-urlencoded"},
      body: URI.encode_www_form(
        client_id: @client_id,
        client_secret: @client_secret,
        grant_type: "client_credentials",
        scope: "https://management.azure.com/.default",
      ),
      expects: 200,
    )
    payload = JSON.parse(response.body)
    @access_token = payload.fetch("access_token")
    @access_token_expires_at = Time.now + payload.fetch("expires_in").to_i - 60
    @access_token
  rescue Excon::Error => e
    response = e.respond_to?(:response) ? e.response : nil
    raise AzureAPIError.new(response&.status, response&.body)
  end
end
