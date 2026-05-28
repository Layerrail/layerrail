# frozen_string_literal: true

require "excon"
require "json"
require "uri"

class CloudflareDnsClient
  def self.configured?
    !!api_token && !!Config.cloudflare_dns_zone_id
  end

  def self.api_token
    Config.cloudflare_dns_api_token || Config.cloudflare_api_token
  end

  def initialize(api_token: self.class.api_token, zone_id: Config.cloudflare_dns_zone_id)
    fail "CLOUDFLARE_DNS_API_TOKEN or CLOUDFLARE_API_TOKEN is required" unless api_token
    fail "CLOUDFLARE_DNS_ZONE_ID is required" unless zone_id

    @zone_id = zone_id
    @connection = Excon.new(
      "https://api.cloudflare.com",
      headers: {
        "Authorization" => "Bearer #{api_token}",
        "Content-Type" => "application/json",
      },
    )
  end

  def sync_zone(dns_zone)
    current_records(dns_zone).each_value do |record|
      if record.tombstoned
        delete_record(name: record.name, type: record.type, content: record.data)
      else
        upsert_record(name: record.name, type: record.type, ttl: record.ttl, content: record.data)
      end
    end
  end

  def upsert_record(name:, type:, ttl:, content:)
    name = normalize_name(name)
    matches = list_records(type:, name:).select { it["content"] == content }
    payload = {
      type:,
      name:,
      content:,
      ttl: cloudflare_ttl(ttl),
      proxied: proxied_record?(type),
    }

    if matches.empty?
      request(:post, records_path, body: payload)
    else
      keep, *duplicates = matches
      request(:patch, "#{records_path}/#{keep.fetch("id")}", body: payload)
      duplicates.each { |record| request(:delete, "#{records_path}/#{record.fetch("id")}") }
    end
  end

  def delete_record(name:, type:, content:)
    name = normalize_name(name)
    list_records(type:, name:).each do |record|
      next if content && record["content"] != content

      request(:delete, "#{records_path}/#{record.fetch("id")}")
    end
  end

  private

  def current_records(dns_zone)
    dns_zone.records_dataset.order(:created_at).all.to_h do |record|
      [[record.name, record.type, record.data], record]
    end
  end

  def list_records(type:, name:)
    query = URI.encode_www_form(type:, name:)
    response = request(:get, "#{records_path}?#{query}")
    response.fetch("result")
  end

  def request(method, path, body: nil)
    response = @connection.public_send(method, path:, body: body&.to_json, expects: [200, 201, 202, 204])
    return {"success" => true, "result" => []} if response.body.to_s.empty?

    parsed = JSON.parse(response.body)
    return parsed if parsed["success"] != false

    fail "Cloudflare DNS API failed: #{parsed.fetch("errors", []).map { it["message"] }.join(", ")}"
  rescue Excon::Error => ex
    fail "Cloudflare DNS API request failed: #{ex.message}"
  end

  def records_path
    "/client/v4/zones/#{@zone_id}/dns_records"
  end

  def normalize_name(name)
    name.to_s.delete_suffix(".")
  end

  def cloudflare_ttl(ttl)
    # Cloudflare does not accept very low TTLs on normal DNS-only records.
    [ttl.to_i, 60].max
  end

  def proxied_record?(type)
    Config.cloudflare_dns_proxied && %w[A AAAA CNAME].include?(type)
  end
end
