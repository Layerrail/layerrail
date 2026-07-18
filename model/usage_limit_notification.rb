# frozen_string_literal: true

require_relative "../model"

class UsageLimitNotification < Sequel::Model
  many_to_one :usage_limit, read_only: true

  plugin ResourceMethods, etc_type: true

  def deliver!
    DB.transaction do
      lock!
      return false if delivered_at

      limit = UsageLimit[usage_limit_id]
      return false unless limit

      UsageLimitEmail.deliver(limit, threshold, current_cost:)
      now = Time.now
      update(delivered_at: now)
      limit.this.update(
        last_notification_threshold: Sequel.function(:greatest, :last_notification_threshold, threshold),
        updated_at: now,
      )
    end
    true
  end
end

# Table: usage_limit_notification
# Columns:
#  id             | uuid                     | PRIMARY KEY
#  usage_limit_id | uuid                     | NOT NULL
#  period_start   | date                     | NOT NULL
#  revision       | integer                  | NOT NULL
#  threshold      | integer                  | NOT NULL
#  current_cost   | numeric                  | NOT NULL
#  created_at     | timestamp with time zone | NOT NULL DEFAULT now()
#  delivered_at   | timestamp with time zone |