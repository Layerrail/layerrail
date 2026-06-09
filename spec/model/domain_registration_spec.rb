# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DomainRegistration do
  let(:account) { Account.create(email: "owner@layerrail.test") }
  let(:project) { account.create_project_with_default_policy("test") }

  it "normalizes and validates domain names" do
    expect(described_class.normalize_domain(" LayerRail.COM. ")).to eq "layerrail.com"
    expect(described_class.valid_domain?("layerrail.com")).to be true
    expect(described_class.valid_domain?("not a domain")).to be false
  end

  it "creates ids with the domain registration prefix" do
    domain_registration = described_class.new_with_id(
      project_id: project.id,
      domain: "layerrail.com",
      status: "cart",
      provider: "namesilo",
      years: 1,
      currency: "usd",
      registration_price_cents: 1200,
      renewal_price_cents: 1400,
      transfer_price_cents: 1300,
      amount_cents: 1200
    )
    domain_registration.save_changes

    expect(domain_registration.ubid).to start_with UBID::TYPE_DOMAIN_REGISTRATION
    expect(domain_registration.path).to eq "/domain/#{domain_registration.ubid}"
    expect(domain_registration.amount_label).to eq "$12.00"
    expect(domain_registration.unit_price_label).to eq "$12.00/yr"
  end

  it "rejects unsupported statuses, providers, and registration periods" do
    domain_registration = described_class.new(
      project_id: project.id,
      domain: "layerrail.com",
      status: "unknown",
      provider: "other",
      years: 11,
      amount_cents: 0
    )

    expect(domain_registration.valid?).to be false
    expect(domain_registration.errors).not_to be_empty
  end
end
