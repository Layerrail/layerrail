# frozen_string_literal: true

require_relative "../model"
require "countries"
require "excon"

class BillingInfo < Sequel::Model
  one_to_many :payment_methods, order: Sequel.desc(:created_at), remover: nil, clearer: nil
  one_to_one :project, read_only: true

  plugin ResourceMethods

  def billing_data
    if Config.polar_access_token
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
        raise unless e.status == 404

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

  def has_address?
    !billing_data&.[]("address").to_s.empty?
  end

  def country
    ISO3166::Country.new(billing_data["country"]) if billing_data["country"]
  end

  def after_destroy
    if Config.stripe_secret_key && !Config.polar_access_token
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
