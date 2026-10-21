# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "customer maintenance" do
  before do
    allow(Config).to receive_messages(customer_maintenance_enabled?: true, api_url: "https://api.console.layerrail.test")
  end

  it "shows scheduled maintenance for console login" do
    page.driver.get("/login")

    expect(page.status_code).to eq(503)
    expect(page.body).to include("Undergoing scheduled maintenance", "https://status.layerrail.com")
    expect(page).to have_css('link[rel="stylesheet"][href*="app.css"]', visible: :all)
    expect(page.response_headers).to include("cache-control" => "no-store", "retry-after" => "3600")
  end

  it "rejects inference before credentials or provider calls" do
    page.driver.get("/v1/models", {}, {"HTTP_HOST" => "api.console.layerrail.test"})

    expect(page.status_code).to eq(503)
    expect(JSON.parse(page.body)).to include("status" => "maintenance")
    expect(JSON.parse(page.body).fetch("error").fetch("type")).to eq("ScheduledMaintenance")
  end

  it "rejects customer write requests before application handlers" do
    %w[/v1/chat/completions /ai/v1/chat/completions /runtime/callback /webhook/bachs /project/example].each do |path|
      page.driver.post(path, "{}", {"CONTENT_TYPE" => "application/json"})

      expect(page.status_code).to eq(503), path
      expect(JSON.parse(page.body)).to include("status" => "maintenance")
    end
  end

  it "blocks edge resolution without touching customer origins" do
    page.driver.get("/edge-runtime/resolve", {"host" => "example.edge.layerrail.com"})

    expect(page.status_code).to eq(503)
  end

  it "keeps live process and database readiness checks available" do
    paths = %w[/up /ready]
    %w[console.layerrail.test api.console.layerrail.test admin.localhost layerrail-web.onrender.com].each do |host|
      paths.each do |path|
        page.driver.get(path, {}, {"HTTP_HOST" => host})

        expect(page.status_code).to eq(200), "#{host}#{path}"
        expect(JSON.parse(page.body)).to include("status" => "ok")
      end
    end
  end

  it "preserves sessionless HEAD health probes" do
    page.driver.submit(:head, "/", {})

    expect(page.status_code).to eq(200)
  end

  it "keeps admin login available without bypassing admin authentication" do
    page.driver.get("/login", {}, {"HTTP_HOST" => URI(Config.admin_url).host})

    expect(page.status_code).to eq(200)
    expect(page.body).to include("Login")
    page.driver.get("/", {}, {"HTTP_HOST" => URI(Config.admin_url).host})
    expect(page.status_code).to eq(302)
    expect(page.response_headers.fetch("location")).to include("/login")
  end

  it "does not allow a forwarded admin host to bypass customer maintenance" do
    page.driver.get("/login", {}, {"HTTP_HOST" => "console.layerrail.test", "HTTP_X_FORWARDED_HOST" => URI(Config.admin_url).host})

    expect(page.status_code).to eq(503)
  end

  it "serves maintenance page assets" do
    page.driver.get("/brand/layerrail/layerrail-favicon.png")

    expect(page.status_code).to eq(200)
  end

  it "returns to normal customer login when the flag is disabled" do
    allow(Config).to receive(:customer_maintenance_enabled?).and_return(false)
    page.driver.get("/login")

    expect(page.status_code).to eq(200)
    expect(page.body).to include("Login")
  end
end
