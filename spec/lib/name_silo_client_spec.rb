# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe NameSiloClient do
  before do
    allow(Config).to receive(:domains_provider).and_return("namesilo")
    allow(Config).to receive(:namesilo_api_key).and_return("namesilo_test")
    allow(Config).to receive(:namesilo_api_base_url).and_return("https://www.namesilo.test/api")
    allow(Config).to receive(:domain_registration_markup_percent).and_return(30.0)
    allow(Config).to receive(:domain_registration_discount_percent).and_return(10.0)
  end

  it "checks domain registration availability" do
    request = stub_request(:get, "https://www.namesilo.test/api/checkRegisterAvailability")
      .with(query: hash_including(
        "version" => "1",
        "type" => "json",
        "key" => "namesilo_test",
        "domains" => "layerrail.com"
      ))
      .to_return(status: 200, body: JSON.generate({
        "reply" => {
          "code" => 300,
          "available" => {"domain" => "layerrail.com"},
          "unavailable" => {}
        }
      }))

    expect(described_class.new.check_register_availability(" LayerRail.COM. ")).to include(
      domain: "layerrail.com",
      available: true
    )
    expect(request).to have_been_requested
  end

  it "calculates registration pricing with markup and intro discount" do
    stub_request(:get, "https://www.namesilo.test/api/getPrices")
      .with(query: hash_including("key" => "namesilo_test"))
      .to_return(status: 200, body: JSON.generate({
        "reply" => {
          "code" => 300,
          "prices" => {
            "com" => {
              "registration" => "10.00",
              "renew" => "12.00",
              "transfer" => "11.00"
            }
          }
        }
      }))

    pricing = described_class.new.registration_pricing("layerrail.com")

    expect(pricing).to include(
      base_registration_price_cents: 1000,
      registration_price_cents: 1170,
      discount_cents: 130,
      renewal_price_cents: 1200,
      transfer_price_cents: 1100
    )
  end

  it "raises a helpful error when NameSilo rejects a request" do
    stub_request(:get, "https://www.namesilo.test/api/checkRegisterAvailability")
      .to_return(status: 200, body: JSON.generate({
        "reply" => {
          "code" => 280,
          "detail" => "Invalid API key"
        }
      }))

    expect {
      described_class.new.check_register_availability("layerrail.com")
    }.to raise_error(NameSiloAPIError, /Invalid API key/)
  end
end
