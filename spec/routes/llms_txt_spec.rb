# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "llms.txt" do
  it "serves the canonical llms.txt file without authentication" do
    get "/llms.txt"

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to start_with("text/plain")
    expect(last_response.body).to include("# LayerRail")
    expect(last_response.body).to include("https://console.layerrail.com/llms-full.txt")
  end

  it "serves the full context file without authentication" do
    get "/llms-full.txt"

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to start_with("text/plain")
    expect(last_response.body).to include("## Core Product Capabilities")
  end

  it "serves llms files from subpath aliases" do
    get "/docs/llms.txt"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq(File.read("public/llms.txt"))

    get "/project/example/llms-full.txt"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq(File.read("public/llms-full.txt"))
  end

  it "serves llms files on API and admin hosts before authentication" do
    header "Host", "api.ubicloud.com"
    get "/llms.txt"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("# LayerRail")

    header "Host", "admin.ubicloud.com"
    get "/llms-full.txt"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("# LayerRail")
  end
end
