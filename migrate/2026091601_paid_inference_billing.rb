# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_record) do
      add_column :inference_invoiced_amount, :numeric, null: false, default: 0
      add_constraint(:inference_invoiced_amount_nonnegative, Sequel[:inference_invoiced_amount] >= 0)
    end
    alter_table(:project) do
      add_column :inference_billing_remainder, :numeric, null: false, default: 0
      add_constraint(:inference_billing_remainder_nonnegative, Sequel[:inference_billing_remainder] >= 0)
    end
    alter_table(:invoice) do
      add_column :billing_kind, :text, null: false, default: "standard"
      add_constraint(:invoice_billing_kind, billing_kind: ["standard", "inference_usage"])
      add_index [:project_id, :billing_kind, :status], concurrently: false
    end
  end
end
