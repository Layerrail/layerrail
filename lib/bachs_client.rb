# frozen_string_literal: true

require "excon"
require "json"
require "uri"

class BachsAPIError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
    super("Bachs API request failed with HTTP #{status}: #{body}")
  end
end

class BachsClient
  def self.enabled?
    !Config.bachs_api_key.to_s.empty?
  end

  def self.invoice_checkout_enabled?
    enabled? && Config.billing_checkout_provider == "bachs"
  end

  def self.verification_checkout_enabled?
    invoice_checkout_enabled? && !Config.bachs_verification_product_id.to_s.empty?
  end

  def self.request(method, path, body: nil, query: nil, expected_status: 200, idempotency_key: nil)
    url = "#{Config.bachs_api_base_url}#{path}"
    url = "#{url}#{path.include?("?") ? "&" : "?"}#{URI.encode_www_form(query.compact)}" if query && !query.empty?
    headers = {
      "Accept" => "application/json",
      "Authorization" => "Bearer #{Config.bachs_api_key}",
      "Content-Type" => "application/json"
    }
    headers["Idempotency-Key"] = idempotency_key if idempotency_key
    response = Excon.public_send(method, url, headers:, body: body && JSON.generate(body), expects: Array(expected_status))
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue Excon::Error => e
    response = e.response
    raise BachsAPIError.new(response&.status, response&.body)
  end

  def self.list_products
    request(:get, "/v1/products")
  end

  def self.create_product(payload, idempotency_key: nil)
    request(:post, "/v1/products", body: payload, expected_status: 201, idempotency_key:)
  end

  def self.archive_product(id)
    request(:post, "/v1/products/#{id}/archive", expected_status: [200, 204])
  end

  def self.create_checkout(payload, idempotency_key: nil)
    request(:post, "/v1/checkout-sessions", body: payload, expected_status: 201, idempotency_key:)
  end

  def self.get_checkout(id)
    request(:get, "/v1/checkout-sessions/#{id}")
  end

  def self.get_subscription(id)
    request(:get, "/v1/subscriptions/#{id}")
  end

  def self.create_refund(payload, idempotency_key: nil)
    request(:post, "/v1/refunds", body: payload, expected_status: [200, 201], idempotency_key:)
  end

  def self.create_webhook_endpoint(payload)
    request(:post, "/v1/webhooks/endpoints", body: payload, expected_status: 201)
  end
end
