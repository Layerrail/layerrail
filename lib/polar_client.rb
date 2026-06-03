# frozen_string_literal: true

require "excon"
require "json"
require "uri"

class PolarAPIError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
    super("Polar API request failed with HTTP #{status}: #{body}")
  end
end

class PolarClient
  def self.enabled?
    !!Config.polar_access_token
  end

  def self.configured_for_checkout?
    enabled? && !!verification_product_id
  end

  def self.verification_product_id
    Config.polar_verification_product_id || Config.polar_checkout_product_id
  end

  def self.request(method, path, body: nil, query: nil, expected_status: 200)
    expected_statuses = Array(expected_status)
    url = "#{Config.polar_api_base_url}#{path}"
    url = "#{url}#{path.include?("?") ? "&" : "?"}#{URI.encode_www_form(query.compact)}" if query && !query.empty?
    response = Excon.public_send(
      method,
      url,
      headers: {
        "Accept" => "application/json",
        "Authorization" => "Bearer #{Config.polar_access_token}",
        "Content-Type" => "application/json"
      },
      body: body && JSON.generate(body),
      expects: expected_statuses
    )

    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue Excon::Error => e
    response = e.response
    raise PolarAPIError.new(response&.status, response&.body)
  end

  def self.create_checkout(payload)
    request(:post, "/checkouts/", body: payload, expected_status: 201)
  end

  def self.list_products
    request(:get, "/products/?limit=100")
  end

  def self.list_orders(filters = {})
    request(:get, "/orders/", query: {limit: 100}.merge(filters))
  end

  def self.create_refund(payload)
    request(:post, "/refunds/", body: payload, expected_status: 201)
  end

  def self.create_product(payload)
    request(:post, "/products/", body: payload, expected_status: 201)
  end

  def self.update_product(id, payload)
    request(:patch, "/products/#{id}", body: payload)
  end

  def self.get_checkout(id)
    request(:get, "/checkouts/#{id}")
  end

  def self.get_customer_by_external_id(external_id)
    request(:get, "/customers/external/#{external_id}")
  end

  def self.update_customer_by_external_id(external_id, payload)
    request(:patch, "/customers/external/#{external_id}", body: payload)
  end

  def self.create_customer_session(external_id, return_url:)
    request(
      :post,
      "/customer-sessions/",
      body: {
        external_customer_id: external_id,
        return_url:
      },
      expected_status: 201
    )
  end

  def self.refund_checkout_order(checkout_id:, external_customer_id:, product_id:, attempts: 3)
    order = nil
    attempts.times do |attempt|
      order = list_orders(checkout_id:, external_customer_id:, product_id:, limit: 1).fetch("items", []).first
      break if order

      sleep(0.5 * (attempt + 1)) if attempt < attempts - 1
    end

    return {status: "order_not_found"} unless order

    total_amount = Integer(order["total_amount"] || 0)
    refunded_amount = Integer(order["refunded_amount"] || 0)
    refundable_amount = total_amount - refunded_amount
    return {status: "already_refunded", order:} unless refundable_amount.positive?

    refund = create_refund(
      order_id: order.fetch("id"),
      reason: "customer_request",
      amount: refundable_amount,
      revoke_benefits: false,
      comment: "Automatic LayerRail billing verification refund",
      metadata: {
        kind: "billing_verification",
        checkout_id:,
        external_customer_id:
      }
    )

    {status: "refunded", order:, refund:}
  end
end
