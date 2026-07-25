# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "health checks" do
  def parsed_body
    JSON.parse(last_response.body)
  end

  it "returns console liveness and readiness without authentication" do
    get "/up"
    expect(last_response.status).to eq(200)
    expect(parsed_body.slice("status", "service")).to eq("status" => "ok", "service" => "console")

    get "/ready"
    expect(last_response.status).to eq(200)
    expect(parsed_body.slice("status", "service", "database")).to eq("status" => "ok", "service" => "console", "database" => "ok")
  end

  it "reports the hosting revision when available" do
    allow(ENV).to receive(:[]).with("RENDER_GIT_COMMIT").and_return("revision-123")

    get "/up"

    expect(last_response.status).to eq(200)
    expect(parsed_body["revision"]).to eq("revision-123")
  end

  it "returns API liveness and readiness without a personal access token" do
    header "Host", "api.ubicloud.com"
    get "/up"
    expect(last_response.status).to eq(200)
    expect(parsed_body.slice("status", "service")).to eq("status" => "ok", "service" => "api")

    header "Host", "api.ubicloud.com"
    get "/ready"
    expect(last_response.status).to eq(200)
    expect(parsed_body.slice("status", "service", "database")).to eq("status" => "ok", "service" => "api", "database" => "ok")
  end

  it "returns admin liveness and readiness without authentication" do
    header "Host", "admin.ubicloud.com"
    get "/up"
    expect(last_response.status).to eq(200)
    expect(parsed_body.slice("status", "service")).to eq("status" => "ok", "service" => "admin")

    header "Host", "admin.ubicloud.com"
    get "/ready"
    expect(last_response.status).to eq(200)
    expect(parsed_body.slice("status", "service", "database")).to eq("status" => "ok", "service" => "admin", "database" => "ok")
  end
end
