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
  SUCCESS_CODES = %w[250 251 252 253 254 260 261 262 263 264 265 280 281 300 301 302].freeze
  REQUEST_TIMEOUT_SECONDS = 12
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
  CORE_ACQUISITION_TLD_PRICES_CENTS = {
    "com" => 999,
    "net" => 999,
    "org" => 899,
    "co" => 699,
    "dev" => 999,
    "app" => 999,
    "xyz" => 99,
    "online" => 199
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
    reply = request("getPrices")
    catalog = tld_catalog_from_reply(reply)
    tld = DomainTld.matching_tld_for_domain(domain, candidate_tlds: catalog.map { it[:tld] })
    catalog_item = catalog.find { |item| item[:tld] == tld }

    unless catalog_item
      return DomainTld.apply_admin_pricing(domain, {
        tld: tld || DomainTld.requested_tld_for_domain(domain),
        tld_enabled: false,
        raw: reply
      })
    end

    DomainTld.apply_admin_pricing(domain, catalog_item.merge(tld_enabled: true, raw: reply))
  end

  def tld_catalog
    tld_catalog_from_reply(request("getPrices"))
  end

  def register_domain(domain_registration)
    params = {
      domain: domain_registration.domain,
      years: domain_registration.years,
      private: 1,
      auto_renew: domain_registration.auto_renew ? 1 : 0
    }
    contact_profile = domain_registration.contact_profile
    if contact_profile&.provider_contact_id
      params[:contact_id] = contact_profile.provider_contact_id
      params[:registrant_contact_id] = contact_profile.provider_contact_id
      params[:administrative_contact_id] = contact_profile.provider_contact_id
      params[:technical_contact_id] = contact_profile.provider_contact_id
      params[:billing_contact_id] = contact_profile.provider_contact_id
    end
    nameservers_from(domain_registration.nameservers).each_with_index do |nameserver, index|
      params[:"ns#{index + 1}"] = nameserver
    end

    request("registerDomain", params)
  end

  def create_contact_profile(contact_profile)
    reply = request("contactAdd", contact_profile.to_namesilo_params)
    contact_id = reply["contact_id"] || reply["contactid"] || reply.dig("contact", "id") || reply["id"]
    [reply, contact_id]
  end

  def change_nameservers(domain, nameservers)
    nameservers = nameservers_from(nameservers)
    return {} if nameservers.empty?

    params = {domain: DomainRegistration.normalize_domain(domain)}
    nameservers.each_with_index { |nameserver, index| params[:"ns#{index + 1}"] = nameserver }
    request("changeNameServers", params)
  end

  def renew_domain(domain_order)
    request(
      "renewDomain",
      domain: domain_order.domain,
      years: domain_order.years
    )
  end

  def transfer_domain(domain_order)
    request(
      "transferDomain",
      domain: domain_order.domain,
      auth: domain_order.auth_code,
      years: domain_order.years,
      private: 1
    )
  end

  def enable_auto_renew(domain)
    request("addAutoRenewal", domain: DomainRegistration.normalize_domain(domain))
  end

  def disable_auto_renew(domain)
    request("removeAutoRenewal", domain: DomainRegistration.normalize_domain(domain))
  end

  def enable_domain_lock(domain)
    request("domainLock", domain: DomainRegistration.normalize_domain(domain))
  end

  def disable_domain_lock(domain)
    request("domainUnlock", domain: DomainRegistration.normalize_domain(domain))
  end

  def add_dnssec_record(domain, keytag:, algorithm:, digest_type:, digest:)
    request(
      "dnsSecAddRecord",
      domain: DomainRegistration.normalize_domain(domain),
      keytag:,
      alg: algorithm,
      digesttype: digest_type,
      digest:
    )
  end

  def delete_dnssec_record(domain, keytag:, algorithm:, digest_type:, digest:)
    request(
      "dnsSecDeleteRecord",
      domain: DomainRegistration.normalize_domain(domain),
      keytag:,
      alg: algorithm,
      digesttype: digest_type,
      digest:
    )
  end

  def forward_domain(domain, target_url:, forwarding_type: "302")
    request(
      "domainForward",
      domain: DomainRegistration.normalize_domain(domain),
      protocol: URI(target_url).scheme || "https",
      address: target_url,
      method: forwarding_type == "301" ? 301 : 302
    )
  end

  private

  def request(operation, params = {})
    fail NameSiloAPIError.new("Domain registrar is not configured.") unless self.class.configured?

    query = {
      version: 1,
      type: "json",
      key: Config.namesilo_api_key
    }.merge(params)

    response = Excon.get(
      "#{Config.namesilo_api_base_url}/#{operation}?#{URI.encode_www_form(query)}",
      expects: [200],
      connect_timeout: REQUEST_TIMEOUT_SECONDS,
      read_timeout: REQUEST_TIMEOUT_SECONDS,
      write_timeout: REQUEST_TIMEOUT_SECONDS
    )
    body = JSON.parse(response.body)
    reply = body["reply"] || body
    code = reply["code"].to_s

    unless code.empty? || SUCCESS_CODES.include?(code)
      fail NameSiloAPIError.new(reply["detail"] || reply["message"] || "NameSilo #{operation} failed with code #{code}", reply)
    end

    reply
  rescue Excon::Error => ex
    response_body = ex.respond_to?(:response) ? ex.response&.body : nil
    fail NameSiloAPIError.new(response_body || "Domain registrar did not respond in time. Please try again.")
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

  def tld_catalog_from_reply(reply)
    items = []
    collect_tld_prices(reply) do |tld, tld_prices|
      items << pricing_from_tld_hash(tld, tld_prices)
    end
    items.uniq { it[:tld] }.sort_by { it[:tld] }
  end

  def collect_tld_prices(object, &block)
    case object
    when Hash
      object.each do |key, value|
        tld = DomainTld.normalize_tld(key)
        if value.is_a?(Hash) && DomainTld.valid_tld_name?(tld) && price_from(value, /^(registration|register|new)$/i)
          yield tld, value
        else
          collect_tld_prices(value, &block)
        end
      end
    when Array
      object.each { collect_tld_prices(it, &block) }
    end
  end

  def pricing_from_tld_hash(tld, tld_prices)
    base_registration_price_cents = price_from(tld_prices, /^(registration|register|new)$/i) || DEFAULT_TLD_PRICES_CENTS.fetch(tld, 1995)
    base_renewal_price_cents = price_from(tld_prices, /renew/i) || base_registration_price_cents
    base_transfer_price_cents = price_from(tld_prices, /transfer/i) || base_renewal_price_cents
    registration_price_before_discount_cents = apply_markup(base_registration_price_cents)
    registration_price_cents = apply_registration_discount(registration_price_before_discount_cents)
    registration_price_cents = [CORE_ACQUISITION_TLD_PRICES_CENTS.fetch(tld, registration_price_cents), 0].max

    {
      tld:,
      provider: "namesilo",
      base_registration_price_cents:,
      base_renewal_price_cents:,
      base_transfer_price_cents:,
      registration_price_cents:,
      discount_cents: [registration_price_before_discount_cents - registration_price_cents, 0].max,
      renewal_price_cents: base_renewal_price_cents,
      transfer_price_cents: base_transfer_price_cents,
      raw: tld_prices
    }
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
    return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A\$?\d{1,3}(?:,\d{3})*(?:\.\d+)?\z/) || value.to_s.match?(/\A\$?\d+(?:\.\d+)?\z/)

    (BigDecimal(value.to_s.delete("$,")) * 100).round(0).to_i
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

  def nameservers_from(value)
    Array(value).flat_map { it.to_s.split(/[\s,]+/) }
      .map { it.strip.downcase.delete_suffix(".") }
      .reject(&:empty?)
      .uniq
      .first(13)
  end
end
