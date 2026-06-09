# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:domain_registration) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :dns_zone_id, :dns_zone, type: :uuid, on_delete: :set_null

      column :domain, String, null: false, collate: '"C"'
      column :status, String, null: false, default: "cart", collate: '"C"'
      column :provider, String, null: false, default: "namesilo", collate: '"C"'
      column :provider_order_id, String, collate: '"C"'
      column :provider_domain_id, String, collate: '"C"'
      column :checkout_id, String, collate: '"C"'
      column :years, Integer, null: false, default: 1
      column :currency, String, null: false, default: "usd", collate: '"C"'
      column :registration_price_cents, Integer, null: false, default: 0
      column :renewal_price_cents, Integer, null: false, default: 0
      column :transfer_price_cents, Integer, null: false, default: 0
      column :discount_cents, Integer, null: false, default: 0
      column :amount_cents, Integer, null: false, default: 0
      column :contact_data, :jsonb, null: false, default: "{}"
      column :provider_payload, :jsonb, null: false, default: "{}"
      column :failure_message, String
      column :expires_at, :timestamptz
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:project_id, :domain], unique: true
      index [:project_id, :status]
      index :checkout_id
      index :dns_zone_id
    end

    run <<~SQL
      ALTER TABLE domain_registration
        ADD CONSTRAINT valid_domain_registration_status
        CHECK (status IN ('cart', 'pending_payment', 'registering', 'active', 'failed', 'cancelled'));

      ALTER TABLE domain_registration
        ADD CONSTRAINT valid_domain_registration_provider
        CHECK (provider IN ('namesilo'));

      ALTER TABLE domain_registration
        ADD CONSTRAINT valid_domain_registration_years
        CHECK (years BETWEEN 1 AND 10);

      ALTER TABLE domain_registration
        ADD CONSTRAINT valid_domain_registration_amount
        CHECK (
          registration_price_cents >= 0 AND
          renewal_price_cents >= 0 AND
          transfer_price_cents >= 0 AND
          discount_cents >= 0 AND
          amount_cents >= 0
        );
    SQL
  end

  down do
    drop_table(:domain_registration)
  end
end
