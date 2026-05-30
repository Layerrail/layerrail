# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "deploy" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:installation) { GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: project.id) }
  let(:location) { Location.where(visible: true).order(:ui_name).first }

  before do
    login(user.email)
    installation
    allow(Config).to receive(:compute_provider).and_return(nil)
    allow(Config).to receive(:github_app_name).and_return("layerrail")
    allow(Config).to receive(:github_app_id).and_return("12345")
    allow(Config).to receive(:github_app_private_key).and_return("private-key")
    allow(Config).to receive(:polar_access_token).and_return(nil)
    allow(Config).to receive(:stripe_secret_key).and_return(nil)
  end

  it "can list and open the deploy creation flow" do
    visit "#{project.path}/deploy"

    expect(page.title).to eq("LayerRail - Deploy")
    expect(page).to have_content "No deploy apps"

    click_link "New Deploy App"
    expect(page.title).to eq("LayerRail - New Deploy App")
    expect(page).to have_content "GitHub account"
  end

  it "can create a deploy app from a GitHub repository" do
    vm_size_name, vm_size_label = DeployApp.vm_size_options.first

    visit "#{project.path}/deploy/create"
    fill_in "App name", with: "web"
    select "test-user (User)", from: "GitHub account"
    fill_in "Repository", with: "test-user/web"
    fill_in "Branch", with: "main"
    select location.ui_name, from: "Location"
    select vm_size_label, from: "VM size"
    select "Node.js", from: "Runtime"
    fill_in "App port", with: "3000"
    fill_in "Root directory", with: "apps/web"
    fill_in "Install command", with: "npm ci"
    fill_in "Build command", with: "npm run build"
    fill_in "Start command", with: "npm start"
    click_button "Create"

    app = DeployApp.first(name: "web")
    expect(page.title).to eq("LayerRail - web")
    expect(page).to have_flash_notice("LayerRail Deploy app is being provisioned")
    expect(app.project_id).to eq(project.id)
    expect(app.installation_id).to eq(installation.id)
    expect(app.location_id).to eq(location.id)
    expect(app.vm_size).to eq(vm_size_name)
    expect(app.repository).to eq("test-user/web")
    expect(app.hostname).to end_with(".apps.layerrail.com")
    expect(DeployDeployment.first(app_id: app.id).status).to eq("queued")
  end

  it "rejects VM sizes outside the LayerRail Deploy v1 catalog" do
    visit "#{project.path}/deploy/create"
    fill_in "App name", with: "web"
    fill_in "Repository", with: "test-user/web"
    select location.ui_name, from: "Location"
    page.driver.browser.dom.css("select[name=vm_size] option").first["value"] = "gpu-rtx6000"
    click_button "Create"

    expect(page.title).to eq("LayerRail - New Deploy App")
    expect(page).to have_flash_error(/vm_size/)
    expect(DeployApp.count).to eq(0)
  end
end
