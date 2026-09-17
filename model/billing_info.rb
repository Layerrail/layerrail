# frozen_string_literal: true

require_relative "../model"
require "countries"
require "excon"

class BillingInfo < Sequel::Model
  one_to_many :payment_methods, order: Sequel.desc(:created_at), remover: nil, clearer: nil
  one_to_one :project, read_only: true

  plugin ResourceMethods

  class BachsCustomerError < StandardError; end

  def bachs_customer_id
    stored_id = self[:bachs_customer_id]
    return stored_id if self.class.valid_bachs_customer_id?(stored_id)

    ids = bachs_receipt_customer_ids
    ids.first if ids.one?
  end

  # Older verified checkouts stored the provider customer on their receipt.
  def bachs_receipt_customer_ids
    payment_methods.filter_map do |payment_method|
      next unless payment_method.stripe_id.start_with?("bachs:payment:")
      next unless payment_method.card_fingerprint.to_s.start_with?("bachs:")

      customer_id = payment_method.card_fingerprint.to_s.delete_prefix("bachs:")
      customer_id if self.class.valid_bachs_customer_id?(customer_id)
    end.uniq
  end

  def self.valid_bachs_customer_id?(id)
    /\Acust_[a-zA-Z0-9_]+\z/.match?(id.to_s)
  end

  def bachs?
    Config.billing_checkout_provider == "bachs" || stripe_id.start_with?("bachs:") || !bachs_customer_id.nil?
  end

  def ensure_bachs_customer!(account:)
    DB.transaction do
      lock!
      if (customer_id = bachs_customer_id)
        update(bachs_customer_id: customer_id) unless self[:bachs_customer_id] == customer_id
        next customer_id
      end

      if self[:bachs_customer_id] || bachs_receipt_customer_ids.length > 1
        raise BachsCustomerError, "We couldn't identify your Bachs billing profile. Contact support@layerrail.com."
      end

      # A billing form's email is editable and is not proof of customer identity.
      raise BachsCustomerError, "Verify your account email before opening Bachs billing." unless account.status_id == 2

      email = account.email.to_s.strip
      raise BachsCustomerError, "Your account needs a verified email for Bachs billing." if email.empty?

      result = BachsClient.list_customers(search: email)
      unless result.is_a?(Hash) && result["items"].is_a?(Array) && result["items"].all? { it.is_a?(Hash) } && result.dig("pagination", "has_more") == false
        raise BachsCustomerError, "We couldn't identify your Bachs billing profile. Contact support@layerrail.com."
      end
      customers = result["items"].select { it["email"].to_s.casecmp?(email) }
      if customers.length > 1
        raise BachsCustomerError, "We couldn't identify your Bachs billing profile. Contact support@layerrail.com."
      end

      # A lost provider response must not create another customer on retry.
      customer = customers.first || BachsClient.create_customer(
        {email:, name: account.name || email},
        idempotency_key: "layerrail-billing-customer-#{id}"
      )
      customer_id = customer["customer_id"]
      unless self.class.valid_bachs_customer_id?(customer_id) && customer["email"].to_s.casecmp?(email)
        raise BachsCustomerError, "We couldn't verify your Bachs billing profile. Contact support@layerrail.com."
      end

      update(bachs_customer_id: customer_id)
      customer_id
    end
  end

  def billing_data
    if bachs?
      @billing_data ||= begin
        return {} unless (customer_id = bachs_customer_id)

        data = BachsClient.get_customer(customer_id)
        address = data["billing_address"] || {}
        metadata = data["metadata"] || {}
        {
          "name" => data["name"],
          "email" => data["email"],
          "address" => [address["line1"], address["line2"]].compact.join(" "),
          "country" => address["country"],
          "city" => address["city"],
          "state" => address["state"],
          "postal_code" => address["postal_code"],
          "tax_id" => metadata["tax_id"],
          "company_name" => metadata["company_name"],
          "note" => metadata["note"]
        }
      rescue BachsAPIError => e
        raise unless e.status == 404

        {}
      end
    elsif Config.polar_access_token
      @billing_data ||= begin
        return {} unless project

        data = PolarClient.get_customer_by_external_id(project.ubid)
        address = data["billing_address"] || {}
        metadata = data["metadata"] || {}
        tax_id = data["tax_id"]
        tax_id = tax_id.values.first if tax_id.is_a?(Hash)
        tax_id = tax_id.first if tax_id.is_a?(Array)
        {
          "name" => data["name"],
          "email" => data["email"],
          "address" => [address["line1"], address["line2"]].compact.join(" "),
          "country" => address["country"],
          "city" => address["city"],
          "state" => address["state"],
          "postal_code" => address["postal_code"],
          "tax_id" => tax_id,
          "company_name" => metadata["company_name"],
          "note" => metadata["note"]
        }
      rescue PolarAPIError => e
        raise unless e.status == 404 || (e.status == 422 && e.body.to_s.include?("Customer does not exist"))

        {}
      end
    elsif Config.stripe_secret_key
      @stripe_data ||= begin
        data = StripeClient.customers.retrieve(stripe_id)
        return nil unless data

        address = data["address"] || {}
        metadata = data["metadata"] || {}
        {
          "name" => data["name"],
          "email" => data["email"],
          "address" => [address["line1"], address["line2"]].compact.join(" "),
          "country" => address["country"],
          "city" => address["city"],
          "state" => address["state"],
          "postal_code" => address["postal_code"],
          "tax_id" => metadata["tax_id"],
          "company_name" => metadata["company_name"],
          "note" => metadata["note"],
        }
      end
    end
  end

  alias_method :stripe_data, :billing_data

  def polar_external_customer_id
    return if bachs?
    return unless Config.polar_access_token
    return stripe_id.delete_prefix("polar:") if stripe_id.to_s.start_with?("polar:")

    project&.ubid
  end

  def has_address?
    !billing_data&.[]("address").to_s.empty?
  end

  def country
    data = billing_data || {}
    ISO3166::Country.new(data["country"]) if data["country"]
  end

  def after_destroy
    if !bachs? && Config.stripe_secret_key && !Config.polar_access_token
      StripeClient.customers.delete(stripe_id)
    end
    super
  end

  VAT_COUNTRY_CODES = {"GR" => "EL"}.freeze

  def validate_vat
    country_code = VAT_COUNTRY_CODES.fetch(billing_data["country"], billing_data["country"])
    response = Excon.get("https://ec.europa.eu/taxation_customs/vies/rest-api/ms/#{country_code}/vat/#{billing_data["tax_id"]}", expects: 200)
    case (status = JSON.parse(response.body)["userError"])
    when "VALID"
      true
    when "INVALID", "INVALID_INPUT"
      false
    else
      fail "Unexpected response from VAT service: #{status}"
    end
  end
end

# Table: billing_info
# Columns:
#  id         | uuid                     | PRIMARY KEY
#  stripe_id  | text                     | NOT NULL
#  created_at | timestamp with time zone | NOT NULL DEFAULT now()
#  valid_vat  | boolean                  |
# Indexes:
#  billing_info_pkey          | PRIMARY KEY btree (id)
#  billing_info_stripe_id_key | UNIQUE btree (stripe_id)
# Referenced By:
#  payment_method | payment_method_billing_info_id_fkey | (billing_info_id) REFERENCES billing_info(id)
#  project        | project_billing_info_id_fkey        | (billing_info_id) REFERENCES billing_info(id)
