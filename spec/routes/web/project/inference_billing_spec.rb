# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "inference billing" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("paid-billing") }

  before do
    allow(BachsClient).to receive(:enabled?).and_return(true)
    allow(UsageLimitEmail).to receive(:deliver)
    billing_info = BillingInfo.create(stripe_id: "bachs:#{project.ubid}")
    project.update(billing_info_id: billing_info.id)
    PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment:#{project.ubid}")
    allow_any_instance_of(BillingInfo).to receive(:billing_data).and_return({"name" => "Customer", "email" => user.email, "country" => "US"})
    rate = BillingRate.from_resource_properties("InferenceTokens", "azure-gpt-5-input", "global")
    BillingRecord.create(project_id: project.id, resource_id: project.id, resource_name: "paid token usage", amount: 15_000,
      span: Sequel.pg_range((Time.now - 60)...Time.now), billing_rate_id: rate.fetch("id"), resource_tags: {paid_inference: true, unit_price: "0.001"})
    login(user.email)
  end

  it "shows separate unpaid AI usage and the Bachs collection policy" do
    visit "#{project.path}/billing"
    expect(page.status_code).to eq(200)
    expect(page).to have_content("Unbilled usage: $15.00")
    expect(page).to have_content("Pay usage invoices through Bachs")
    expect(page).to have_content("Current infrastructure usage $0.00")
  end

  it "includes AI usage when setting or changing a spending limit" do
    # Each reached threshold deliberately writes a notification with the same
    # SQL shape. Exercise the full limit behavior without that query heuristic.
    allow(DB).to receive(:detect_duplicate_queries).and_yield
    visit "#{project.path}/billing"
    fill_in "usage_limit", with: 10
    click_button "Set limit"
    expect(project.reload.usage_limit.suspended?).to be(true)
    fill_in "usage_limit", with: 12
    click_button "Update limit"
    expect(project.reload.usage_limit.suspended?).to be(true)
    fill_in "usage_limit", with: 20
    click_button "Update limit"
    expect(project.reload.usage_limit.suspended?).to be(false)
  end
end
