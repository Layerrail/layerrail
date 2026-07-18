# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "outbound HTTP security" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("security-project") }

  before do
    login(user.email)
  end

  it "rejects a private Edge origin" do
    visit "#{project.path}/edge/create"
    fill_in "Name", with: "private-origin"
    fill_in "Origin URL", with: "http://127.0.0.1:3000/ready"
    click_button "Create Edge Service"

    expect(page).to have_content("must resolve only to public IP addresses")
    expect(project.edge_services_dataset).to be_empty
  end

  it "rejects a cloud metadata uptime target" do
    visit "#{project.path}/monitoring/uptime/create"
    fill_in "Name", with: "metadata"
    fill_in "Target URL", with: "http://169.254.169.254/latest/meta-data"
    click_button "Create Uptime Check"

    expect(page).to have_content("must resolve only to public IP addresses")
    expect(project.uptime_checks_dataset).to be_empty
  end

  it "rejects a private monitoring webhook" do
    visit "#{project.path}/monitoring/notification-channels/create"
    fill_in "Name", with: "private-webhook"
    select "Webhook", from: "kind"
    fill_in "Target", with: "https://10.0.0.1/hook"
    click_button "Create Channel"

    expect(page).to have_content("must resolve only to public IP addresses")
    expect(project.monitoring_notification_channels_dataset).to be_empty
  end
end
