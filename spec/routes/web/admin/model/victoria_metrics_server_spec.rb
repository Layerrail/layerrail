# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VictoriaMetricsServer" do
  include AdminModelSpecHelper

  before do
    @instance = create_victoria_metrics_server
    admin_account_setup_and_login
  end

  it "displays the VictoriaMetricsServer instance page correctly" do
    click_link "VictoriaMetricsServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "LayerRail Admin - VictoriaMetricsServer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "LayerRail Admin - VictoriaMetricsServer #{@instance.ubid}"
  end
end
