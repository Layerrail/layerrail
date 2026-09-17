# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:invoice_email_delivery) do
      foreign_key :invoice_id, :invoice, type: :uuid, null: false, on_delete: :cascade
      String :notification_type, null: false
      primary_key [:invoice_id, :notification_type]
      String :status, null: false, default: "pending"
      String :message, text: true
      String :idempotency_scope
      String :provider_message_id
      String :last_error_class
      Integer :attempts, null: false, default: 0
      Integer :generation, null: false, default: 1
      DateTime :first_attempt_at
      DateTime :last_attempt_at
      DateTime :next_attempt_at
      DateTime :sent_at
      constraint(:invoice_email_delivery_status, status: %w[pending sending sent needs_review])
    end
  end
end
