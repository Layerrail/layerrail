# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:domain_registration) do
      add_column :dnssec_enabled, TrueClass, null: false, default: false
      add_column :dnssec_records, :jsonb, null: false, default: "[]"
      add_column :forwarding_enabled, TrueClass, null: false, default: false
      add_column :forwarding_url, String, collate: '"C"'
      add_column :forwarding_type, String, collate: '"C"'
      add_column :project_attached_at, :timestamptz
      add_column :abuse_status, String, null: false, default: "clear", collate: '"C"'
      add_column :abuse_reason, String
      add_column :abuse_flagged_at, :timestamptz
      add_column :notifications_enabled, TrueClass, null: false, default: true
      add_column :last_notification_at, :timestamptz
      add_column :next_auto_renewal_at, :timestamptz
      add_index [:project_id, :abuse_status]
      add_index :next_auto_renewal_at
    end

    alter_table(:domain_order) do
      add_column :scheduled_by_automation, TrueClass, null: false, default: false
      add_column :due_at, :timestamptz
      add_column :completed_at, :timestamptz
      add_index :due_at
    end

    run <<~SQL
      ALTER TABLE domain_registration
        ADD CONSTRAINT valid_domain_registration_forwarding_type
        CHECK (forwarding_type IS NULL OR forwarding_type IN ('301', '302', 'masked'));

      ALTER TABLE domain_registration
        ADD CONSTRAINT valid_domain_registration_abuse_status
        CHECK (abuse_status IN ('clear', 'review', 'locked'));
    SQL
  end

  down do
    run <<~SQL
      ALTER TABLE domain_registration
        DROP CONSTRAINT IF EXISTS valid_domain_registration_abuse_status;

      ALTER TABLE domain_registration
        DROP CONSTRAINT IF EXISTS valid_domain_registration_forwarding_type;
    SQL

    alter_table(:domain_order) do
      drop_index :due_at
      drop_column :completed_at
      drop_column :due_at
      drop_column :scheduled_by_automation
    end

    alter_table(:domain_registration) do
      drop_index :next_auto_renewal_at
      drop_index [:project_id, :abuse_status]
      drop_column :next_auto_renewal_at
      drop_column :last_notification_at
      drop_column :notifications_enabled
      drop_column :abuse_flagged_at
      drop_column :abuse_reason
      drop_column :abuse_status
      drop_column :project_attached_at
      drop_column :forwarding_type
      drop_column :forwarding_url
      drop_column :forwarding_enabled
      drop_column :dnssec_records
      drop_column :dnssec_enabled
    end
  end
end
