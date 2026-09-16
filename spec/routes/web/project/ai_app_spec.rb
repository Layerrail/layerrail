# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "AI app model availability" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("ai-app-availability") }
  let(:available_model) { "@cf/meta/llama-3.2-1b-instruct" }

  before do
    allow(Config).to receive_messages(ai_inference_enabled: true, ai_inference_provider: "cloudflare")
    login(user.email)
  end

  it "offers available text models while retaining unavailable models in the main catalog" do
    visit "#{project.path}/ai-app?tab=create"

    choices = page.all("select[name='model_name'] option").map { it[:value] }
    expect(choices).to include(available_model)
    expect(choices).not_to include("@cf/moonshotai/kimi-k2.6", "minimax/m3", "@cf/baai/bge-small-en-v1.5")

    visit "#{project.path}/inference-endpoint"
    expect(page).to have_content("MiniMax M3")
    expect(page).to have_content("Kimi K2.6")
  end

  ["@cf/moonshotai/kimi-k2.6", "minimax/m3"].each do |unavailable_model|
    it "rejects a submitted unavailable model #{unavailable_model}" do
      visit "#{project.path}/ai-app?tab=create"
      csrf_token = find("form[action='#{project.path}/ai-app'] input[name='_csrf']", visible: false).value

      expect {
        page.driver.post "#{project.path}/ai-app", {
          _csrf: csrf_token, name: "unavailable-agent", model_name: unavailable_model,
        }
      }.not_to change(AiAgent, :count)

      expect(page.status_code).to eq(400)
    end
  end

  it "creates an app using an available model" do
    visit "#{project.path}/ai-app?tab=create"
    fill_in "App name", with: "available-agent"
    find("select[name='model_name'] option[value='#{available_model}']").select_option

    expect { click_button "Create App" }.to change(AiAgent, :count).by(1)

    expect(project.ai_agents_dataset.first(name: "available-agent").model_name).to eq(available_model)
    expect(page).to have_flash_notice("App endpoint created")
  end

  it "preserves the display and stored model of an existing app whose model became unavailable" do
    agent = AiAgent.create(
      project_id: project.id, name: "existing-agent", model_name: "@cf/moonshotai/kimi-k2.6",
      description: "Existing app", system_prompt: "Reply briefly.",
    )

    visit "#{project.path}#{agent.path}"

    expect(page.status_code).to eq(200)
    expect(page).to have_content(agent.name)
    expect(page).to have_content(agent.model_name)
    expect(agent.reload.model_name).to eq("@cf/moonshotai/kimi-k2.6")
  end
end
