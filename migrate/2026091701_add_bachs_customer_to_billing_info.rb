# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_info) do
      add_column :bachs_customer_id, String
    end
  end
end
