# frozen_string_literal: true

require "bigdecimal"
require "excon"
require "json"
require "uri"

class NameSiloAPIError < StandardError
  attr_reader :response

  def initialize(message, response = nil)
    @response = response
    super(message)
  end
end

class NameSiloClient
  SUCCESS_CODES = %w[300 301 302].freeze
  DEFAULT_TLD_PRICES_CENTS = {
    "com" => 1395,
    "net" => 1495,
    "org" => 1295,
    "co" => 2995,
    "io" => 3995,
    "ai" => 8995,
    "dev" => 1595,
    "app" => 1595,
    "online" => 3495,
    "xyz" => 1295
  }.freeze

  def self.configured?
    Config.domains_provider == "namesilo" && Config.namesilo_api_key
  end

  def check_register_availability(domain)
    domain = DomainRegistration.normalize_domain(domain)
    reply = request("checkRegisterAvailability", domains: domain)
    available_domains = domains_from(reply["available"])
    unavailable_domains = domains_from(reply["unavailable"])

    if available_domains.empty? && unavailable_domains.empty?
      available_domains = collect_matching_domains(reply, domain, /(available|success)/i)
      unavailable_domains = collect_matching_domains(reply, domain, /(unavailable|invalid|taken|error)/i)
    end

    {
      domain:,
      available: available_domains.include?(domain) && !unavailable_domains.include?(domain),
      raw: reply
    }
  end

  def registration_pricing(domain)
    domain = DomainRegistration.normalize_domain(domain)
    tld = domain.split(".").last
    reply = request("getPrices")
    tld_prices = find_tld_hash(reply, tld)
    base_registration_price_cents = price_from(tld_prices, /^(registration|register|new)$/i) || DEFAULT_TLD_PRICES_CENTS.fetch(tld, 1995)
    renewal_price_cents = price_from(tld_prices, /renew/i) || base_registration_price_cents
    transfer_price_cents = price_from(tld_prices, /transfer/i) || renewal_price_cents
    registration_price_before_discount_cents = apply_markup(base_registration_price_cents)
    registration_price_cents = apply_registration_discount(registration_price_before_discount_cents)

    {
      base_registration_price_cents:,
      registration_price_cents:,
      discount_cents: [registration_price_before_discount_cents - registration_price_cents, 0].max,
      renewal_price_cents:,
      transfer_price_cents:,
      raw: reply
    }
  end

  def register_domain(domain_registration)
    request(
      "registerDomain",
      domain: domain_registration.domain,
      years: domain_registration.years,
      private: 1,
      auto_renew: 0
    )
  end

  private

  def request(operation, params = {})
    fail NameSiloAPIError.new("NameSilo is not configured. Set NAMESILO_API_KEY.") unless self.class.configured?

    query = {
      version: 1,
      type: "json",
      key: Config.namesilo_api_key
    }.merge(params)

    response = Excon.get("#{Config.namesilo_api_base_url}/#{operation}?#{URI.encode_www_form(query)}", expects: [200])
    body = JSON.parse(response.body)
    reply = body["reply"] || body
    code = reply["code"].to_s

    unless code.empty? || SUCCESS_CODES.include?(code)
      fail NameSiloAPIError.new(reply["detail"] || reply["message"] || "NameSilo #{operation} failed with code #{code}", reply)
    end

    reply
  rescue Excon::Error => ex
    fail NameSiloAPIError.new(ex.response&.body || ex.message)
  rescue JSON::ParserError => ex
    fail NameSiloAPIError.new(ex.message)
  end

  def domains_from(value)
    case value
    when nil
      []
    when String
      value.split(/[\s,]+/).map { DomainRegistration.normalize_domain(it) }.reject(&:empty?)
    when Array
      value.flat_map { domains_from(it) }
    when Hash
      value.flat_map { |key, nested_value| [DomainRegistration.normalize_domain(key), *domains_from(nested_value)] }
    else
      []
    end
  end

  def collect_matching_domains(object, domain, state_pattern)
    case object
    when Hash
      object.flat_map do |key, value|
        matches = []
        matches << domain if DomainRegistration.normalize_domain(key) == domain && value.to_s.match?(state_pattern)
        matches + collect_matching_domains(value, domain, state_pattern)
      end
    when Array
      object.flat_map { collect_matching_domains(it, domain, state_pattern) }
    else
      []
    end.uniq
  end

  def find_tld_hash(object, tld)
    case object
    when Hash
      object.each do |key, value|
        return value if key.to_s.downcase.delete_prefix(".") == tld

        found = find_tld_hash(value, tld)
        return found if found
      end
    when Array
      object.each do |value|
        found = find_tld_hash(value, tld)
        return found if found
      end
    end

    nil
  end

  def price_from(object, key_pattern)
    case object
    when Hash
      object.each do |key, value|
        cents = price_to_cents(value) if key.to_s.match?(key_pattern)
        return cents if cents
      end

      object.each_value do |value|
        cents = price_from(value, key_pattern)
        return cents if cents
      end
    when Array
      object.each do |value|
        cents = price_from(value, key_pattern)
        return cents if cents
      end
    else
      price_to_cents(object)
    end
  end

  def price_to_cents(value)
    return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A\$?\d+(?:\.\d+)?\z/)

    (BigDecimal(value.to_s.delete("$")) * 100).round(0).to_i
  rescue ArgumentError
    nil
  end

  def apply_markup(cents)
    percent = Config.domain_registration_markup_percent.to_f
    return cents if percent <= 0

    (cents * (1 + (percent / 100.0))).round
  end

  def apply_registration_discount(cents)
    discount_percent = Config.domain_registration_discount_percent.to_f
    return cents if discount_percent <= 0

    [(cents * (1 - (discount_percent / 100.0))).round, 0].max
  end
end
