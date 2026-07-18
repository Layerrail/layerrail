# frozen_string_literal: true

require "base64"
require "excon"
require "json"
require "uri"

class IonosAPIError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
    super("IONOS API request failed with HTTP #{status}: #{body}")
  end
end

class IonosClient
  OperationResult = Struct.new(:body, :status_url, keyword_init: true)

  def self.enabled?
    !!Config.ionos_api_token || (!!Config.ionos_username && !!Config.ionos_password)
  end

  def initialize(api_token: Config.ionos_api_token, username: Config.ionos_username, password: Config.ionos_password, base_url: Config.ionos_api_base_url)
    @headers = {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
      "User-Agent" => "LayerRail/1.0",
    }

    if api_token
      @headers["Authorization"] = "Bearer #{api_token}"
    elsif username && password
      @headers["Authorization"] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
    else
      raise "IONOS_API_TOKEN or IONOS_USERNAME/IONOS_PASSWORD is required to provision Game VPS servers"
    end

    uri = URI(base_url)
    @path_prefix = uri.path.delete_suffix("/")
    uri.path = ""
    uri.query = nil
    uri.fragment = nil
    @base_url = uri.to_s.delete_suffix("/")
    @connection = Excon.new(@base_url, headers: @headers)
  end

  def create_datacenter(name:, location:)
    request(
      :post,
      "/datacenters",
      body: {
        properties: {
          name:,
          description: "LayerRail Game VPS #{name}",
          location:,
        },
      },
      expected_status: [200, 201, 202],
    )
  end

  def create_lan(datacenter_id:, name:)
    request(
      :post,
      "/datacenters/#{datacenter_id}/lans",
      body: {
        properties: {
          name:,
          public: true,
        },
      },
      expected_status: [200, 201, 202],
    )
  end

  def create_server(datacenter_id:, name:, cores:, ram_gib:, cpu_family:, image_alias:, image_password:, disk_gib:, disk_type:, lan_id:)
    properties = {
      name:,
      hostname: name,
      cores:,
      ram: ram_gib * 1024,
      availabilityZone: "AUTO",
      vmState: "RUNNING",
      type: "ENTERPRISE",
    }
    properties[:cpuFamily] = cpu_family unless cpu_family.to_s.empty?

    request(
      :post,
      "/datacenters/#{datacenter_id}/servers?depth=5",
      body: {
        properties:,
        entities: {
          volumes: {
            items: [
              {
                properties: {
                  name: "#{name}-system",
                  size: disk_gib,
                  type: disk_type,
                  bus: "VIRTIO",
                  imageAlias: image_alias,
                  imagePassword: image_password,
                  licenceType: "WINDOWS",
                },
              },
            ],
          },
          nics: {
            items: [
              {
                properties: {
                  name: "#{name}-public",
                  dhcp: true,
                  lan: lan_id,
                  firewallActive: true,
                  firewallType: "BIDIRECTIONAL",
                },
                entities: {
                  firewallrules: {
                    items: firewall_rules,
                  },
                },
              },
            ],
          },
        },
      },
      expected_status: [200, 201, 202],
    )
  end

  def get_server(datacenter_id, server_id)
    request(:get, "/datacenters/#{datacenter_id}/servers/#{server_id}?depth=5").body
  end

  def stop_server(datacenter_id, server_id)
    request(:post, "/datacenters/#{datacenter_id}/servers/#{server_id}/stop", expected_status: [202])
  end

  def start_server(datacenter_id, server_id)
    request(:post, "/datacenters/#{datacenter_id}/servers/#{server_id}/start", expected_status: [202])
  end

  def get_request_status(status_url)
    request(:get, status_path(status_url)).body
  end

  def request_done?(status_url)
    return true if status_url.to_s.empty?

    body = get_request_status(status_url)
    status = body.dig("metadata", "status") ||
      body.dig("metadata", "state") ||
      body.dig("properties", "status") ||
      body.dig("properties", "requestStatus") ||
      body["status"] ||
      body["state"]
    normalized = status.to_s.upcase
    raise IonosAPIError.new(500, body.to_json) if ["FAILED", "ERROR"].include?(normalized)

    ["DONE", "AVAILABLE", "SUCCESS", "SUCCESSFUL", "FINISHED"].include?(normalized)
  end

  def delete_datacenter(datacenter_id)
    request(:delete, "/datacenters/#{datacenter_id}", expected_status: [202, 204, 404])
  end

  def primary_ip_for(server)
    nic_items = server.dig("entities", "nics", "items") || []
    nic_items.each do |nic|
      ips = nic.dig("properties", "ips") || []
      return ips.first if ips.first
    end
    nil
  end

  private

  def firewall_rules
    [
      firewall_rule("LayerRail RDP", "TCP", 3389),
      firewall_rule("FiveM TCP", "TCP", 30120),
      firewall_rule("FiveM UDP", "UDP", 30120),
      firewall_rule("txAdmin", "TCP", 40120),
    ]
  end

  def firewall_rule(name, protocol, port)
    {
      properties: {
        name:,
        protocol:,
        portRangeStart: port,
        portRangeEnd: port,
        sourceIp: "0.0.0.0/0",
      },
    }
  end

  def status_path(status_url)
    uri = URI(status_url)
    path = uri.host ? "#{uri.path}#{("?#{uri.query}" if uri.query)}" : status_url
    path = path.delete_prefix(@path_prefix) if path.start_with?("#{@path_prefix}/")

    path
  end

  def request(method, path, body: nil, expected_status: 200)
    response = @connection.public_send(
      method,
      path: path.start_with?("http") ? path : "#{@path_prefix}#{path}",
      body: body && JSON.generate(body),
      expects: Array(expected_status),
    )
    OperationResult.new(
      body: response.body.to_s.empty? ? {} : JSON.parse(response.body),
      status_url: response.headers["Location"] || response.headers["location"],
    )
  rescue Excon::Error => e
    response = e.respond_to?(:response) ? e.response : nil
    raise IonosAPIError.new(response&.status, response&.body)
  end
end
