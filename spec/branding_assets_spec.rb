# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "LayerRail branding assets" do
  it "keeps root logo fallbacks aligned with LayerRail brand assets" do
    expect(File.binread("public/logo-primary.png")).to eq(File.binread("public/brand/layerrail/layerrail-console-logo.png"))
    expect(File.binread("public/logo-white.png")).to eq(File.binread("public/brand/layerrail/layerrail-console-logo-white.png"))
  end

  it "keeps the root favicon aligned with the LayerRail favicon" do
    favicon = File.binread("public/favicon.ico")
    layerrail_png = File.binread("public/brand/layerrail/layerrail-favicon.png")

    expect(favicon).to include(layerrail_png)
  end

  it "uses the LayerRail color for the LayerRail chart palette entry" do
    chart_js = File.read("assets/js/app.js")

    expect(chart_js).to include("color: '#8B67F2',\n    class: 'layerrail-500'")
    expect(chart_js).not_to include("#fc8452")
  end
end
