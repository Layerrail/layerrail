# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "Bachs billing portal" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-bachs") }
  let(:billing_info) do
    billing_info = BillingInfo.create(stripe_id: "polar:legacy-project", bachs_customer_id: "cust_existing")
    project.update(billing_info_id: billing_info.id)
    billing_info
  end

  before do
    allow(Config).to receive_messages(billing_checkout_provider: "bachs", polar_access_token: "old-polar-token")
    allow(BachsClient).to receive(:enabled?).and_return(true)
    allow(BachsClient).to receive(:get_customer).with("cust_existing").and_return("name" => "Owner", "email" => user.email)
    expect(PolarClient).not_to receive(:get_customer_by_external_id)
    expect(PolarClient).not_to receive(:create_customer_session)
    billing_info
    login(user.email)
  end

  it "renders Bachs billing details and preserves the previous connection as history" do
    PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "polar:checkout:old")

    visit "#{project.path}/billing"

    expect(page.status_code).to eq(200)
    expect(page).to have_link("Open Bachs Billing Profile", href: "#{project.path}/billing/portal")
    expect(page).to have_content("Previous billing connection; manage new payments through Bachs")
    expect(page).to have_no_content("Managed in the Polar customer portal")
    expect(page).to have_no_field("Billing Name")
    expect(billing_info.refresh.stripe_id).to eq("polar:legacy-project")
  end

  it "creates a new short-lived portal session on each open without caching its credential" do
    portal_url = "https://portal.bachs.io/s/test-only-session"
    expect(BachsClient).to receive(:create_customer_portal_session).with("cust_existing").twice.and_return("id" => "psn_1", "url" => portal_url)

    2.times do
      page.driver.get "#{project.path}/billing/portal"
      expect(page.driver.response.status).to eq(303)
      expect(page.driver.response.headers).to include("location" => portal_url, "cache-control" => "no-store", "referrer-policy" => "no-referrer")
    end
    expect(billing_info.refresh.values.values).not_to include(portal_url)
  end

  it "keeps the legacy record when Bachs cannot open the portal and logs only its status" do
    expect(BachsClient).to receive(:create_customer_portal_session).and_raise(BachsAPIError.new(503, "private provider response"))
    expect(Clog).to receive(:emit).with("Bachs billing portal unavailable", {bachs_portal_failed: {project_id: project.id, status: 503}})

    visit "#{project.path}/billing/portal"

    expect(page.status_code).to eq(200)
    expect(page).to have_current_path("#{project.path}/billing")
    expect(page).to have_flash_error("We couldn't open Bachs billing. Please try again or contact support@layerrail.com.")
    expect(billing_info.refresh.stripe_id).to eq("polar:legacy-project")
    expect(project.refresh.billing_info_id).to eq(billing_info.id)
  end

  it "rejects a malformed portal response without returning a server error" do
    expect(BachsClient).to receive(:create_customer_portal_session).and_return("id" => "psn_1", "url" => nil)

    visit "#{project.path}/billing/portal"

    expect(page.status_code).to eq(200)
    expect(page).to have_flash_error("Bachs returned an invalid billing portal link. Please try again later.")
  end

  it "rejects an insecure portal URL" do
    expect(BachsClient).to receive(:create_customer_portal_session).and_return("id" => "psn_1", "url" => "http://portal.bachs.io/s/test-only")

    visit "#{project.path}/billing/portal"

    expect(page.status_code).to eq(200)
    expect(page).to have_flash_error("Bachs returned an invalid billing portal link. Please try again later.")
  end

  it "does not fall back to Polar when Bachs credentials are unavailable" do
    allow(BachsClient).to receive(:enabled?).and_return(false)
    allow(PolarClient).to receive(:configured_for_checkout?).and_return(true)
    expect(BachsClient).not_to receive(:create_customer_portal_session)

    visit "#{project.path}/billing/portal"

    expect(page).to have_flash_error("Bachs billing is temporarily unavailable. Please try again later.")
  end

  it "requires project billing permission before creating a portal session" do
    restricted_project = user.create_project_with_default_policy("restricted", default_policy: nil)
    restricted_project.update(billing_info_id: billing_info.id)
    expect(BachsClient).not_to receive(:create_customer_portal_session)

    visit "#{restricted_project.path}/billing/portal"

    expect(page.status_code).to eq(403)
  end
end
