# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UsageLimit do
  let(:user) { Account.create(email: "owner@example.com") }
  let(:project) { Project.create(name: "limited-project") }
  let(:usage_limit) { described_class.create(project_id: project.id, user_id: user.id, limit: 100, period_start: Date.new(2026, 7, 1)) }

  it "sends each warning threshold once" do
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, 80, current_cost: 95).ordered
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, 90, current_cost: 95).ordered

    usage_limit.reconcile!(95, now: Time.utc(2026, 7, 17))
    usage_limit.reconcile!(95, now: Time.utc(2026, 7, 17, 1))

    expect(usage_limit.reload.last_notification_threshold).to eq(90)
    expect(usage_limit.suspended?).to be(false)
    expect(usage_limit.notifications_dataset.count).to eq(2)
  end

  it "stops the project and sends all crossed thresholds at 100 percent" do
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, 80, current_cost: 100).ordered
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, 90, current_cost: 100).ordered
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, 100, current_cost: 100).ordered

    usage_limit.reconcile!(100, now: Time.utc(2026, 7, 17))

    expect(usage_limit.reload.last_notification_threshold).to eq(100)
    expect(usage_limit.suspended?).to be(true)
    expect(usage_limit.suspended_revision).to eq(usage_limit.revision)
    expect(project.reload.active?).to be(false)
  end

  it "stays suspended when the 100 percent email fails" do
    usage_limit.update(last_notification_threshold: 90)
    allow(UsageLimitEmail).to receive(:deliver).and_call_original
    allow(UsageLimitEmail).to receive(:deliver).with(usage_limit, 100, current_cost: 100).and_raise("mail unavailable")

    usage_limit.reconcile!(100, now: Time.utc(2026, 7, 17))

    expect(usage_limit.reload.suspended?).to be(true)
    expect(usage_limit.last_notification_threshold).to eq(90)
    expect(project.reload.active?).to be(false)
    expect(usage_limit.notifications_dataset.where(threshold: 100, delivered_at: nil).count).to eq(1)

    allow(UsageLimitEmail).to receive(:deliver).with(usage_limit, 100, current_cost: 100).and_call_original
    expect(Util).to receive(:send_email)
    usage_limit.reconcile!(100, now: Time.utc(2026, 7, 17, 1))
    expect(usage_limit.notifications_dataset.where(threshold: 100).exclude(delivered_at: nil).count).to eq(1)
  end

  it "does not resume until the limit is adjusted above current usage" do
    usage_limit.update(suspended_at: Time.utc(2026, 7, 17), suspended_revision: 1, last_notification_threshold: 100)
    expect(UsageLimitEnforcer).not_to receive(:resume!)

    usage_limit.reconcile!(10, now: Time.utc(2026, 8, 1))

    expect(usage_limit.reload.suspended?).to be(true)
  end

  it "resumes after an effective limit adjustment" do
    usage_limit.update(suspended_at: Time.utc(2026, 7, 17), suspended_revision: 1, last_notification_threshold: 100)
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, :updated, current_cost: 100).ordered
    expect(UsageLimitEnforcer).to receive(:resume!).with(usage_limit).ordered
    expect(UsageLimitEmail).to receive(:deliver).with(usage_limit, :resumed, current_cost: 100).ordered

    usage_limit.adjust!(200, user_id: user.id, current_cost: 100, now: Time.utc(2026, 7, 17, 1))

    expect(usage_limit.reload.suspended?).to be(false)
    expect(usage_limit.limit).to eq(200)
    expect(usage_limit.revision).to eq(2)
  end

  it "stays resumed when the resume email fails" do
    usage_limit.update(limit: 200, revision: 2, suspended_at: Time.utc(2026, 7, 17), suspended_revision: 1, last_notification_threshold: 100)
    allow(UsageLimitEmail).to receive(:deliver).with(usage_limit, :resumed, current_cost: 100).and_raise("mail unavailable")

    usage_limit.reconcile!(100, now: Time.utc(2026, 7, 17, 1))

    expect(usage_limit.reload.suspended?).to be(false)
    expect(project.reload.active?).to be(true)
  end

  it "requires another adjustment after an insufficient increase" do
    usage_limit.update(suspended_at: Time.utc(2026, 7, 17), suspended_revision: 1, last_notification_threshold: 100)
    allow(UsageLimitEmail).to receive(:deliver)
    allow(UsageLimitEnforcer).to receive(:suspend!)

    usage_limit.adjust!(50, user_id: user.id, current_cost: 100, now: Time.utc(2026, 7, 17, 1))

    expect(usage_limit.reload.suspended_revision).to eq(2)
    expect(UsageLimitEnforcer).not_to receive(:resume!)
    usage_limit.reconcile!(0, now: Time.utc(2026, 8, 1))
    expect(usage_limit.reload.suspended?).to be(true)
  end

  it "resumes services when destroyed outside the billing route" do
    usage_limit.update(suspended_at: Time.utc(2026, 7, 17), suspended_revision: 1)
    expect(UsageLimitEnforcer).to receive(:resume!).with(usage_limit)

    usage_limit.destroy
  end

  it "is removed when its project is soft-deleted" do
    usage_limit
    project.soft_delete

    expect(usage_limit.exists?).to be(false)
  end

  it "resets warning state for a new month when not suspended" do
    usage_limit.update(last_notification_threshold: 90)

    usage_limit.reconcile!(0, now: Time.utc(2026, 8, 1))

    expect(usage_limit.reload.period_start).to eq(Date.new(2026, 8, 1))
    expect(usage_limit.last_notification_threshold).to eq(0)
  end
end