# frozen_string_literal: true

require_relative "../model"

class UsageLimitBillingRecord < Sequel::Model
  many_to_one :usage_limit, read_only: true

  unrestrict_primary_key
end

# Table: usage_limit_billing_record
# Columns:
#  usage_limit_id   | uuid    | PRIMARY KEY
#  billing_record_id | uuid   | PRIMARY KEY
#  project_id       | uuid    | NOT NULL
#  resource_id      | uuid    | NOT NULL
#  resource_name    | text    | NOT NULL
#  amount           | numeric | NOT NULL
#  billing_rate_id  | uuid    | NOT NULL
#  resource_tags    | jsonb   | NOT NULL DEFAULT '{}'::jsonb
#  snapshotted_at   | timestamp with time zone | NOT NULL