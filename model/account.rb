# frozen_string_literal: true

require_relative "../model"

class Account < Sequel::Model(:accounts)
  STREAK_PRIMARY_EMOJIS = %w[⚡ 🚀 💎 🔥 🛡️ ✨ 🌐 🛰️ 🧭 🔷 ☀️ 🌙 💜 🧱 🔐 🧪 📡 🏆 👑 💫 🔮 🛠️ 📦 🧬 🧲 🎯 🪩 🧊].freeze
  STREAK_ACCENT_EMOJIS = %w[✦ ✧ ◆ ◇ ◈ ✺ ✹ ✸ ✷ ✶ ✵ ✴ ✳ ✲ ✱ ✰ ✭ ✬ ✫ ✪ ✩].freeze
  STREAK_BADGE_THEMES = [
    ["#8B67F2", "#5A3A38", "#D1C8E7"],
    ["#7C5EF4", "#31224F", "#EBE9F1"],
    ["#9C6BFF", "#452A63", "#D7CBFF"],
    ["#6F57E8", "#233A5F", "#C9D8FF"],
    ["#825EF3", "#184C4F", "#C8F2EE"],
    ["#935DEB", "#4E2F35", "#F1D0D6"],
    ["#7568F0", "#2B335D", "#D3D8FF"],
    ["#8B67F2", "#37512E", "#DCF2D1"],
    ["#7158DF", "#4F3C1F", "#F1E1BE"],
    ["#A166F2", "#47284F", "#E9C8F1"],
    ["#7F6AF2", "#1E4754", "#C8E9F1"],
    ["#8E64E8", "#522B42", "#F1C8DF"],
    ["#7067F2", "#243F57", "#C8DFF1"],
    ["#9667F2", "#3F2C5A", "#DDD1F5"],
    ["#7B5CE8", "#43383E", "#E8DFE3"],
    ["#8B67F2", "#2E3F39", "#D4EEE2"],
    ["#8661EA", "#542E2E", "#F1D0C8"],
    ["#765EF0", "#2E3154", "#D1D6F7"],
    ["#9A66F2", "#4E3143", "#F1D2E5"],
    ["#8068EA", "#263A3F", "#CFE9EA"]
  ].freeze
  STREAK_MILESTONE_EMOJIS = {
    7 => "🔥",
    14 => "⚡",
    30 => "🚀",
    50 => "💎",
    75 => "🌐",
    100 => "👑",
    180 => "🛰️",
    365 => "🏆",
    500 => "💫",
    1000 => "🔮",
    5000 => "🪐",
    10000 => "🌌"
  }.freeze

  one_to_many :usage_alerts, key: :user_id, read_only: true
  one_to_many :usage_limits, key: :user_id, read_only: true
  one_to_many :api_keys, key: :owner_id, conditions: {owner_table: "accounts"}, read_only: true
  one_to_many :identities, class: :AccountIdentity, remover: nil, clearer: nil
  one_to_many :invitations, class: :ProjectInvitation, primary_key: :email, key: :email, read_only: true
  one_to_many :sent_invitations, class: :ProjectInvitation, key: :inviter_id, read_only: true
  many_to_many :projects, join_table: :access_tag, left_key: :hyper_tag_id
  one_through_one :default_project, class: :Project, join_table: :account_default_project, left_key: :id, right_key: :project_id

  plugin :association_dependencies,
    projects: :nullify,
    sent_invitations: :destroy,
    usage_alerts: :destroy,
    usage_limits: :destroy

  plugin ResourceMethods
  include SubjectTag::Cleanup

  alias_method :admin_label, :email

  FREE_MAIL_DOMAINS = %w[gmail.com outlook.com hotmail.com yahoo.com icloud.com protonmail.com proton.me].freeze

  def provider_names
    identities.map(&:provider).join(", ")
  end

  def self.login_streak_columns_available?
    DB[Sequel[:information_schema][:columns]]
      .where(table_schema: "public", table_name: "accounts", column_name: %w[login_streak login_streak_longest login_streak_last_seen_on])
      .count == 3
  rescue Sequel::DatabaseError
    false
  end

  def record_console_visit!(today = Date.today)
    return self unless self.class.login_streak_columns_available?
    return self if login_streak_last_seen_on == today

    next_streak =
      if login_streak_last_seen_on == today - 1
        login_streak + 1
      else
        1
      end

    update(
      login_streak: next_streak,
      login_streak_longest: [login_streak_longest, next_streak].max,
      login_streak_last_seen_on: today
    )
  end

  def login_streak_badge
    return unless self.class.login_streak_columns_available?

    streak = login_streak.to_i
    return if streak < 1

    {
      streak:,
      count_label: streak >= 10_000 ? "#{(streak / 1000.0).round(1)}k" : streak.to_s,
      primary: STREAK_MILESTONE_EMOJIS[streak] || STREAK_PRIMARY_EMOJIS[(streak - 1) % STREAK_PRIMARY_EMOJIS.length],
      accent: STREAK_ACCENT_EMOJIS[((streak - 1) / STREAK_PRIMARY_EMOJIS.length) % STREAK_ACCENT_EMOJIS.length],
      theme: STREAK_BADGE_THEMES[((streak - 1) / (STREAK_PRIMARY_EMOJIS.length * STREAK_ACCENT_EMOJIS.length)) % STREAK_BADGE_THEMES.length],
      label: "#{streak} day streak",
      title: "Current console streak: #{streak} day#{"s" unless streak == 1}. Longest: #{login_streak_longest}."
    }
  end

  def create_project_with_default_policy(name, reputation: "new", default_policy: true)
    reputation = "limited" if FREE_MAIL_DOMAINS.any? { email.end_with?("@#{it}") } && projects.none? { it.reputation == "verified" }
    project = Project.create(name:, reputation:)
    add_project(project)

    if default_policy
      # Grant user Admin access
      admin_subject_tag = SubjectTag.create(project_id: project.id, name: "Admin")
      admin_subject_tag.add_subject(id)
      AccessControlEntry.create(project_id: project.id, subject_id: admin_subject_tag.id)

      # Also create a Member subject tag with access to member actions
      member_subject_tag = SubjectTag.create(project_id: project.id, name: "Member")
      AccessControlEntry.create(project_id: project.id, subject_id: member_subject_tag.id, action_id: ActionTag::MEMBER_ID)
    end

    project
  end

  def first_sole_project_with_resources
    Project
      .where(id: DB[:access_tag]
        .select_group(:project_id)
        .where(project_id: projects_dataset.select(Sequel[:project][:id]))
        .having(Sequel.function(:count).* => 1))
      .first_project_with_resources
  end

  def suspend
    update(suspended_at: Time.now)
    DB[:account_active_session_keys].where(account_id: id).delete(force: true)
    api_keys_dataset.update(is_valid: false)
    PaymentMethod.where(billing_info_id: projects_dataset.select(:billing_info_id)).update(fraud: true)
    ProjectInvitation.where(inviter_id: id).destroy
  end

  def unsuspend
    update(suspended_at: nil)
    PaymentMethod.where(billing_info_id: projects_dataset.select(:billing_info_id)).update(fraud: false)
  end
end

# Table: accounts
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  status_id                 | integer                  | NOT NULL DEFAULT 1
#  email                     | citext                   | NOT NULL
#  name                      | text                     |
#  created_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  suspended_at              | timestamp with time zone |
#  login_streak              | integer                  | NOT NULL DEFAULT 0
#  login_streak_longest      | integer                  | NOT NULL DEFAULT 0
#  login_streak_last_seen_on | date                     |
# Indexes:
#  accounts_pkey        | PRIMARY KEY btree (id)
#  accounts_email_index | UNIQUE btree (email) WHERE status_id = ANY (ARRAY[1, 2])
# Check constraints:
#  valid_email                             | (email ~ '^[^,;@ \r\n]+@[^,@; \r\n]+\.[^,@; \r\n]+$'::citext)
#  valid_login_streak_longest_non_negative | (login_streak_longest >= 0)
#  valid_login_streak_non_negative         | (login_streak >= 0)
# Foreign key constraints:
#  accounts_status_id_fkey | (status_id) REFERENCES account_statuses(id)
# Referenced By:
#  access_tag                       | access_tag_hyper_tag_id_fkey                     | (hyper_tag_id) REFERENCES accounts(id)
#  account_active_session_keys      | account_active_session_keys_account_id_fkey      | (account_id) REFERENCES accounts(id)
#  account_activity_times           | account_activity_times_id_fkey                   | (id) REFERENCES accounts(id)
#  account_default_project          | account_default_project_id_fkey                  | (id) REFERENCES accounts(id) ON DELETE CASCADE
#  account_email_auth_keys          | account_email_auth_keys_id_fkey                  | (id) REFERENCES accounts(id)
#  account_identities               | account_identities_account_id_fkey               | (account_id) REFERENCES accounts(id)
#  account_jwt_refresh_keys         | account_jwt_refresh_keys_account_id_fkey         | (account_id) REFERENCES accounts(id)
#  account_lockouts                 | account_lockouts_id_fkey                         | (id) REFERENCES accounts(id)
#  account_login_change_keys        | account_login_change_keys_id_fkey                | (id) REFERENCES accounts(id)
#  account_login_failures           | account_login_failures_id_fkey                   | (id) REFERENCES accounts(id)
#  account_otp_keys                 | account_otp_keys_id_fkey                         | (id) REFERENCES accounts(id)
#  account_otp_unlocks              | account_otp_unlocks_id_fkey                      | (id) REFERENCES accounts(id)
#  account_password_change_times    | account_password_change_times_id_fkey            | (id) REFERENCES accounts(id)
#  account_password_hashes          | account_password_hashes_id_fkey                  | (id) REFERENCES accounts(id)
#  account_password_reset_keys      | account_password_reset_keys_id_fkey              | (id) REFERENCES accounts(id)
#  account_previous_password_hashes | account_previous_password_hashes_account_id_fkey | (account_id) REFERENCES accounts(id)
#  account_recovery_codes           | account_recovery_codes_id_fkey                   | (id) REFERENCES accounts(id)
#  account_remember_keys            | account_remember_keys_id_fkey                    | (id) REFERENCES accounts(id)
#  account_session_keys             | account_session_keys_id_fkey                     | (id) REFERENCES accounts(id)
#  account_sms_codes                | account_sms_codes_id_fkey                        | (id) REFERENCES accounts(id)
#  account_verification_keys        | account_verification_keys_id_fkey                | (id) REFERENCES accounts(id)
#  account_webauthn_keys            | account_webauthn_keys_account_id_fkey            | (account_id) REFERENCES accounts(id)
#  account_webauthn_user_ids        | account_webauthn_user_ids_id_fkey                | (id) REFERENCES accounts(id)
#  project_invitation               | project_invitation_inviter_id_fkey               | (inviter_id) REFERENCES accounts(id)
#  usage_alert                      | usage_alert_user_id_fkey                         | (user_id) REFERENCES accounts(id)
#  usage_limit                      | usage_limit_user_id_fkey                         | (user_id) REFERENCES accounts(id)
