# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "domains" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  before do
    allow(Config).to receive(:domains_enabled).and_return(true)
    login(user.email)
  end

  it "shows domain management with tabs and without internal planning copy" do
    visit "#{project.path}/domain"

    expect(page.status_code).to eq(200)
    expect(page).to have_link("Registered domains", href: "#{project.path}/domain")
    expect(page).to have_link("Search", href: "#{project.path}/domain/create")
    expect(page).to have_link("Transfers", href: "#{project.path}/domain/transfer")
    expect(page).to have_link("Contact profiles", href: "#{project.path}/domain/contact-profile")
    expect(page).to have_link("Bulk search", href: "#{project.path}/domain/bulk")
    expect(page).to have_no_link("Bundles", href: "#{project.path}/domain/bundle")
    expect(page).to have_no_content("ICANN")
    expect(page).to have_no_content("Phase")
    expect(page).to have_no_content("Provider details")
  end

  it "does not expose the removed ICANN planning page" do
    visit "#{project.path}/domain/icann"

    expect(page.status_code).to eq(404)
  end
end
