# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PolarClient do
  before do
    allow(Config).to receive(:polar_access_token).and_return("polar_test")
    allow(Config).to receive(:polar_api_base_url).and_return("https://api.polar.test/v1")
  end

  it "updates a product" do
    request = stub_request(:patch, "https://api.polar.test/v1/products/product_123")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        },
        body: hash_including(
          name: "LayerRail Verification Package",
          prices: [hash_including(price_amount: 100)]
        )
      )
      .to_return(status: 200, body: JSON.generate({"id" => "product_123"}))

    expect(described_class.update_product("product_123", {
      name: "LayerRail Verification Package",
      prices: [{amount_type: "fixed", price_currency: "usd", price_amount: 100}]
    })).to eq({"id" => "product_123"})
    expect(request).to have_been_requested
  end

  it "updates organization customer portal settings" do
    request = stub_request(:patch, "https://api.polar.test/v1/organizations/org_123")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        },
        body: hash_including(
          customer_portal_settings: hash_including(
            usage: hash_including(show: true)
          )
        )
      )
      .to_return(status: 200, body: JSON.generate({"id" => "org_123"}))

    expect(described_class.update_organization("org_123", {
      customer_portal_settings: {
        usage: {
          show: true
        }
      }
    })).to eq({"id" => "org_123"})
    expect(request).to have_been_requested
  end

  it "lists meters by organization" do
    request = stub_request(:get, "https://api.polar.test/v1/meters/")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        },
        query: {
          "limit" => "100",
          "organization_id" => "org_123",
          "is_archived" => "false"
        }
      )
      .to_return(status: 200, body: JSON.generate({"items" => []}))

    expect(described_class.list_meters(organization_id: "org_123", is_archived: false)).to eq({"items" => []})
    expect(request).to have_been_requested
  end

  it "creates a meter" do
    request = stub_request(:post, "https://api.polar.test/v1/meters/")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        },
        body: hash_including(
          name: "LayerRail Compute",
          organization_id: "org_123"
        )
      )
      .to_return(status: 201, body: JSON.generate({"id" => "meter_123"}))

    expect(described_class.create_meter({
      name: "LayerRail Compute",
      organization_id: "org_123",
      filter: {
        conjunction: "and",
        clauses: [
          {
            property: "name",
            operator: "eq",
            value: "layerrail_usage"
          }
        ]
      },
      aggregation: {
        func: "sum",
        property: "units"
      }
    })).to eq({"id" => "meter_123"})
    expect(request).to have_been_requested
  end

  it "ingests usage events" do
    request = stub_request(:post, "https://api.polar.test/v1/events/ingest")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        },
        body: hash_including(
          events: [
            hash_including(name: "layerrail_usage", external_customer_id: "pj_test")
          ]
        )
      )
      .to_return(status: 200, body: JSON.generate({"inserted" => 1, "duplicates" => 0}))

    expect(described_class.ingest_events([
      {
        name: "layerrail_usage",
        external_customer_id: "pj_test",
        metadata: {
          units: 1
        }
      }
    ])).to eq({"inserted" => 1, "duplicates" => 0})
    expect(request).to have_been_requested
  end

  it "gets customer state by external id" do
    request = stub_request(:get, "https://api.polar.test/v1/customers/external/pj_test/state")
      .with(
        headers: {
          "Authorization" => "Bearer polar_test",
          "Content-Type" => "application/json"
        }
      )
      .to_return(status: 200, body: JSON.generate({"external_id" => "pj_test", "active_meters" => []}))

    expect(described_class.get_customer_state_by_external_id("pj_test")).to eq({"external_id" => "pj_test", "active_meters" => []})
    expect(request).to have_been_requested
  end
end
