# frozen_string_literal: true

require "excon"
require "json"

class LinodeAPIError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
    super("Linode API request failed with HTTP #{status}: #{body}")
  end
end

class LinodeClient
  def self.enabled?
    !!Config.linode_access_token
  end

  def initialize(access_token: Config.linode_access_token, base_url: Config.linode_api_base_url)
    raise "LINODE_ACCESS_TOKEN is required to provision Linode compute" unless access_token

    @connection = Excon.new(
      base_url,
      headers: {
        "Accept" => "application/json",
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => "application/json",
      },
    )
  end

  def create_linode(payload)
    request(:post, "/linode/instances", body: payload, expected_status: 200)
  end

  def get_linode(linode_id)
    request(:get, "/linode/instances/#{linode_id}")
  end

  def delete_linode(linode_id)
    request(:delete, "/linode/instances/#{linode_id}", expected_status: [200, 404])
  end

  def create_volume(label:, region:, size:, linode_id:)
    request(:post, "/volumes", body: {label:, region:, size:, linode_id:}, expected_status: 200)
  end

  def get_volume(volume_id)
    request(:get, "/volumes/#{volume_id}")
  end

  def delete_volume(volume_id)
    request(:delete, "/volumes/#{volume_id}", expected_status: [200, 404])
  end

  def detach_volume(volume_id)
    request(:post, "/volumes/#{volume_id}/detach", expected_status: [200, 404])
  end

  def boot_linode(linode_id)
    request(:post, "/linode/instances/#{linode_id}/boot", expected_status: [200, 208])
  end

  def shutdown_linode(linode_id)
    request(:post, "/linode/instances/#{linode_id}/shutdown", expected_status: [200, 208])
  end

  def reboot_linode(linode_id)
    request(:post, "/linode/instances/#{linode_id}/reboot", expected_status: [200, 208])
  end

  def create_firewall(label:, rules:, tags: [])
    request(:post, "/networking/firewalls", body: {label:, rules:, tags:}, expected_status: 200)
  end

  def update_firewall_rules(firewall_id, rules)
    request(:put, "/networking/firewalls/#{firewall_id}/rules", body: rules)
  end

  def delete_firewall(firewall_id)
    request(:delete, "/networking/firewalls/#{firewall_id}", expected_status: [200, 404])
  end

  private

  def request(method, path, body: nil, expected_status: 200)
    response = @connection.public_send(method, path:, body: body && JSON.generate(body), expects: Array(expected_status))
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue Excon::Error => e
    response = e.response
    raise LinodeAPIError.new(response&.status, response&.body)
  end
end
