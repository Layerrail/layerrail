# frozen_string_literal: true

RSpec.describe PremiumAiTrial do
  let(:project) { Project.create(name: "premium-ai-trial") }
  let(:model) { CloudflareInferenceModel.new("id" => "gpt-5-6-luna", "model_name" => "gpt-5.6-luna", "provider" => "azure_foundry", "tags" => {}) }

  it "never starts a new free trial even if the old trial flag remains enabled" do
    allow(Config).to receive(:premium_ai_trial_enabled).and_return(true)
    expect(described_class.active_for?(project, model)).to be(false)
    expect(described_class.where(project_id: project.id)).to be_empty
  end

  it "preserves existing trial history without granting free requests" do
    now = Time.now.round(6)
    trial_id = SecureRandom.uuid
    DB[:premium_ai_trial].insert(id: trial_id, project_id: project.id, started_at: now, ends_at: now + 30 * 86_400)
    trial = described_class[trial_id]
    expect(described_class.active_for?(project, model, now:)).to be(false)
    expect(trial.reload.ends_at).to eq(now + 30 * 86_400)
  end
end
