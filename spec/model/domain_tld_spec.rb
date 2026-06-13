# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DomainTld do
  before do
    allow(Config).to receive(:domain_registration_markup_percent).and_return(30.0)
    allow(Config).to receive(:domain_registration_discount_percent).and_return(10.0)
  end

  it "matches multi-label ccTLDs using the longest suffix" do
    described_class.upsert_from_admin(
      tld: "ng",
      registration_price_cents: 10_00,
      renewal_price_cents: 10_00,
      transfer_price_cents: 10_00
    )
    described_class.upsert_from_admin(
      tld: "com.ng",
      registration_price_cents: 7_00,
      renewal_price_cents: 7_00,
      transfer_price_cents: 7_00
    )

    expect(described_class.matching_tld_for_domain("example.com.ng")).to eq "com.ng"
  end

  it "syncs provider catalog rows without manual entry" do
    counts = described_class.sync_from_provider_catalog!(
      provider: "namesilo",
      catalog: [
        {
          tld: "com",
          base_registration_price_cents: 10_00,
          base_renewal_price_cents: 12_00,
          base_transfer_price_cents: 11_00,
          registration_price_cents: 11_70,
          renewal_price_cents: 12_00,
          transfer_price_cents: 11_00,
          raw: {"registration" => "10.00"}
        },
        {
          tld: "com.ng",
          base_registration_price_cents: 7_00,
          base_renewal_price_cents: 7_00,
          base_transfer_price_cents: 7_00,
          registration_price_cents: 8_19,
          renewal_price_cents: 7_00,
          transfer_price_cents: 7_00,
          raw: {"registration" => "7.00"}
        }
      ]
    )

    expect(counts).to include(created: 2, updated: 0, skipped: 0)
    expect(described_class.first(tld: "com").registration_price_cents).to eq 11_70
    expect(described_class.first(tld: "com.ng").provider_payload).to include("source" => "provider_sync")
  end

  it "reenables TLDs that are present in the provider catalog" do
    described_class.upsert_from_admin(
      tld: "com",
      enabled: false,
      registration_price_cents: 9_00,
      renewal_price_cents: 9_00,
      transfer_price_cents: 9_00
    )

    described_class.sync_from_provider_catalog!(
      provider: "namesilo",
      catalog: [
        {
          tld: "com",
          base_registration_price_cents: 10_00,
          base_renewal_price_cents: 12_00,
          base_transfer_price_cents: 11_00,
          registration_price_cents: 11_70,
          renewal_price_cents: 12_00,
          transfer_price_cents: 11_00,
          raw: {"registration" => "10.00"}
        }
      ]
    )

    expect(described_class.first(tld: "com")).to be_enabled
  end
end
