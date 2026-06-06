# frozen_string_literal: true

RSpec.describe Account do
  let(:account) { described_class.create(email: "test@example.com") }

  it "removes referencing access control entries and subject tag memberships" do
    project = account.create_project_with_default_policy("project-1", default_policy: false)
    tag = SubjectTag.create(project_id: project.id, name: "t")
    tag.add_member(account.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: account.id)

    account.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end

  it "suspend" do
    now = Time.now
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    project = account.create_project_with_default_policy("project-1")
    ApiKey.create_personal_access_token(account, project:)
    DB[:account_active_session_keys].insert(account_id: account.id, session_id: "session-id")
    project.update(billing_info_id: BillingInfo.create(stripe_id: "cus123").id)
    payment_method = project.billing_info.add_payment_method(stripe_id: "pm123")
    project.add_invitation(inviter_id: account.id, email: "test2@example.com", expires_at: now + 60 * 60)
    expect { account.suspend }
      .to change(account, :suspended_at).from(nil).to(now)
      .and change { DB[:account_active_session_keys].where(account_id: account.id).count }.from(1).to(0)
      .and change { payment_method.reload.fraud }.from(false).to(true)
      .and change { project.invitations_dataset.count }.from(1).to(0)
  end

  it "unsuspend" do
    project = account.create_project_with_default_policy("project-1")
    project.update(billing_info_id: BillingInfo.create(stripe_id: "cus123").id)
    payment_method = project.billing_info.add_payment_method(stripe_id: "pm123")
    payment_method.update(fraud: true)
    account.update(suspended_at: Time.now)
    expect { account.unsuspend }
      .to change(account, :suspended_at).to(nil)
      .and change { payment_method.reload.fraud }.from(true).to(false)
  end

  describe ".create_project_with_default_policy" do
    it "sets reputation new" do
      project = account.create_project_with_default_policy("project-2")
      expect(project.reputation).to eq("new")
    end

    it "sets reputation limited if the email is from gmail" do
      account.email = "test@gmail.com"
      project = account.create_project_with_default_policy("project-2")
      expect(project.reputation).to eq("limited")
    end

    it "sets reputation new if the email is from gmail but has a verified project already" do
      account.email = "test@gmail.com"
      account.add_project(Project.create(name: "project-3", reputation: "verified"))
      project = account.create_project_with_default_policy("project-2")
      expect(project.reputation).to eq("new")
    end
  end

  describe "#record_console_visit!" do
    let(:today) { Date.new(2026, 6, 6) }

    it "starts a streak on the first console visit" do
      expect { account.record_console_visit!(today) }
        .to change { account.reload.login_streak }.from(0).to(1)
        .and change { account.reload.login_streak_longest }.from(0).to(1)
        .and change { account.reload.login_streak_last_seen_on }.from(nil).to(today)
    end

    it "does not double-count same-day visits" do
      account.record_console_visit!(today)

      expect { account.record_console_visit!(today) }
        .not_to change { account.reload.values.slice(:login_streak, :login_streak_longest, :login_streak_last_seen_on) }
    end

    it "increments consecutive daily visits" do
      account.record_console_visit!(today)

      expect { account.record_console_visit!(today + 1) }
        .to change { account.reload.login_streak }.from(1).to(2)
        .and change { account.reload.login_streak_longest }.from(1).to(2)
    end

    it "resets after a missed day but keeps the longest streak" do
      account.record_console_visit!(today)
      account.record_console_visit!(today + 1)

      expect { account.record_console_visit!(today + 3) }
        .to change { account.reload.login_streak }.from(2).to(1)
        .and not_change { account.reload.login_streak_longest }.from(2)
    end
  end

  describe "#login_streak_badge" do
    it "returns no badge without a streak" do
      expect(account.login_streak_badge).to be_nil
    end

    it "returns an emoji badge payload for long streaks" do
      account.update(login_streak: 10_001, login_streak_longest: 10_001, login_streak_last_seen_on: Date.new(2026, 6, 6))

      badge = account.login_streak_badge
      expect(badge[:primary]).not_to be_empty
      expect(badge[:accent]).not_to be_empty
      expect(badge[:theme]).to contain_exactly(a_string_starting_with("#"), a_string_starting_with("#"), a_string_starting_with("#"))
      expect(badge[:count_label]).to eq("10.0k")
      expect(badge[:label]).to eq("10001 day streak")
    end
  end
end
