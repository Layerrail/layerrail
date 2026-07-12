# frozen_string_literal: true

RSpec.describe PremiumAiTrial do
  let(:project) { Project.create(name: "premium-ai-trial") }
  let(:eligible_model) { CloudflareInferenceModel.new("id" => "gpt-5-6-luna", "model_name" => "gpt-5.6-luna", "provider" => "azure_foundry", "tags" => {}) }
  let(:ineligible_model) { CloudflareInferenceModel.new("id" => "gpt-5-mini", "model_name" => "gpt-5-mini", "provider" => "azure_foundry", "tags" => {}) }

  before do
    allow(Config).to receive(:premium_ai_trial_enabled).and_return(true)
    allow(Config).to receive(:premium_ai_trial_days).and_return(30)
  end

  it "starts one 30-day trial for an eligible model" do
    now = Time.utc(2026, 7, 12, 12)

    expect(described_class.active_for?(project, eligible_model, now:)).to be(true)
    trial = described_class.where(project_id: project.id).first
    expect(trial.started_at).to eq(now)
    expect(trial.ends_at).to eq(now + 30 * 24 * 60 * 60)
    expect { described_class.active_for?(project, eligible_model, now: now + 60) }.not_to change(described_class, :count)
  end

  it "does not start a trial for models outside the launch offer" do
    expect(described_class.active_for?(project, ineligible_model)).to be(false)
    expect(described_class.where(project_id: project.id)).to be_empty
  end

  it "stops granting free access when the trial ends" do
    now = Time.utc(2026, 7, 12, 12)
    described_class.active_for?(project, eligible_model, now:)

    expect(described_class.active_for?(project, eligible_model, now: now + 30 * 24 * 60 * 60)).to be(false)
  end
end
