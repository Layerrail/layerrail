# frozen_string_literal: true

require "excon"
require "json"

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

  def self.request(method, path, body: nil, expected_status: 200)
    expected_statuses = Array(expected_status)
    response = Excon.public_send(
      method,
      "#{Config.polar_api_base_url}#{path}",
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

  def self.create_product(payload)
    request(:post, "/products/", body: payload, expected_status: 201)
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
end
