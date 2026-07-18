# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe UsageLimitEmail do
  let(:user) { Account.create(email: "owner@example.com", name: "Owner") }
  let(:project) { Project.create(name: "email-project") }
  let(:usage_limit) { UsageLimit.create(project_id: project.id, user_id: user.id, limit: 125) }

  it "renders the limit-set email with threshold and shutdown behavior" do
    expect(Util).to receive(:send_email).with(
      "owner@example.com",
      "Monthly usage limit set for project email-project",
      hash_including(
        greeting: "Hello Owner,",
        body: array_including(/\$125\.00/, /80%, 90%, and 100%/, /No resources or data are deleted/),
        button_title: "View usage limit",
      ),
    )

    described_class.deliver(usage_limit, :set, current_cost: 0)
  end

  [80, 90, 100].each do |threshold|
    it "renders the #{threshold} percent usage email" do
      expect(Util).to receive(:send_email).with(
        "owner@example.com",
        include("#{threshold}%").or(include("Usage limit reached")),
        hash_including(body: array_including(/\$100\.00/, /\$125\.00/)),
      )

      described_class.deliver(usage_limit, threshold, current_cost: 100)
    end
  end

  it "renders the automatic-resume email" do
    expect(Util).to receive(:send_email).with(
      "owner@example.com",
      "Services resumed for project email-project",
      hash_including(body: array_including(/starting again automatically/)),
    )

    described_class.deliver(usage_limit, :resumed, current_cost: 100)
  end
end