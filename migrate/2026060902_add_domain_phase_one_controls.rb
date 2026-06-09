# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:domain_contact_profile) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false

      column :name, String, null: false, collate: '"C"'
      column :first_name, String, null: false, collate: '"C"'
      column :last_name, String, null: false, collate: '"C"'
      column :organization, String, collate: '"C"'
      column :email, String, null: false, collate: '"C"'
      column :phone, String, null: false, collate: '"C"'
      column :address1, String, null: false, collate: '"C"'
      column :address2, String, collate: '"C"'
      column :city, String, null: false, collate: '"C"'
      column :state, String, null: false, collate: '"C"'
      column :postal_code, String, null: false, collate: '"C"'
      column :country_code, String, null: false, collate: '"C"'
      column :provider, String, null: false, default: "namesilo", collate: '"C"'
      column :provider_contact_id, String, collate: '"C"'
      column :provider_payload, :jsonb, null: false, default: "{}"
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:project_id, :name], unique: true
      index :provider_contact_id
    end

    create_table(:domain_tld) do
      column :id, :uuid, primary_key: true
      column :tld, String, null: false, collate: '"C"'
      column :enabled, TrueClass, null: false, default: true
      column :provider, String, null: false, default: "namesilo", collate: '"C"'
      column :registration_price_cents, Integer, null: false, default: 0
      column :renewal_price_cents, Integer, null: false, default: 0
      column :transfer_price_cents, Integer, null: false, default: 0
      column :base_registration_price_cents, Integer, null: false, default: 0
      column :base_renewal_price_cents, Integer, null: false, default: 0
      column :base_transfer_price_cents, Integer, null: false, default: 0
      column :markup_percent, Float, null: false, default: 0.0
      column :intro_discount_percent, Float, null: false, default: 0.0
      column :provider_payload, :jsonb, null: false, default: "{}"
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :tld, unique: true
      index [:enabled, :tld]
    end

    create_table(:domain_order) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :domain_registration_id, :domain_registration, type: :uuid, on_delete: :set_null
      foreign_key :domain_contact_profile_id, :domain_contact_profile, type: :uuid, on_delete: :set_null

      column :kind, String, null: false, collate: '"C"'
      column :status, String, null: false, default: "cart", collate: '"C"'
      column :provider, String, null: false, default: "namesilo", collate: '"C"'
      column :domain, String, null: false, collate: '"C"'
      column :years, Integer, null: false, default: 1
      column :currency, String, null: false, default: "usd", collate: '"C"'
      column :amount_cents, Integer, null: false, default: 0
      column :checkout_id, String, collate: '"C"'
      column :auth_code, String, collate: '"C"'
      column :provider_order_id, String, collate: '"C"'
      column :provider_payload, :jsonb, null: false, default: "{}"
      column :failure_message, String
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:project_id, :status]
      index [:project_id, :domain]
      index :checkout_id
      index :domain_registration_id
    end

    alter_table(:domain_registration) do
      add_foreign_key :contact_profile_id, :domain_contact_profile, type: :uuid, on_delete: :set_null
      add_column :nameservers, :jsonb, null: false, default: "[]"
      add_column :auto_renew, TrueClass, null: false, default: false
      add_column :last_renewed_at, :timestamptz
      add_column :transferred_at, :timestamptz
      add_index :contact_profile_id
    end

    run <<~SQL
      ALTER TABLE domain_contact_profile
        ADD CONSTRAINT valid_domain_contact_profile_provider
        CHECK (provider IN ('namesilo'));

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_provider
        CHECK (provider IN ('namesilo'));

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_prices
        CHECK (
          registration_price_cents >= 0 AND
          renewal_price_cents >= 0 AND
          transfer_price_cents >= 0 AND
          base_registration_price_cents >= 0 AND
          base_renewal_price_cents >= 0 AND
          base_transfer_price_cents >= 0 AND
          markup_percent >= 0 AND
          intro_discount_percent >= 0 AND
          intro_discount_percent <= 100
        );

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_name
        CHECK (tld ~ '^[a-z0-9][a-z0-9-]{1,62}$');

      ALTER TABLE domain_order
        ADD CONSTRAINT valid_domain_order_kind
        CHECK (kind IN ('renewal', 'transfer'));

      ALTER TABLE domain_order
        ADD CONSTRAINT valid_domain_order_status
        CHECK (status IN ('cart', 'pending_payment', 'processing', 'succeeded', 'failed', 'cancelled'));

      ALTER TABLE domain_order
        ADD CONSTRAINT valid_domain_order_provider
        CHECK (provider IN ('namesilo'));

      ALTER TABLE domain_order
        ADD CONSTRAINT valid_domain_order_years
        CHECK (years BETWEEN 1 AND 10);

      ALTER TABLE domain_order
        ADD CONSTRAINT valid_domain_order_amount
        CHECK (amount_cents >= 0);
    SQL
  end

  down do
    alter_table(:domain_registration) do
      drop_index :contact_profile_id
      drop_column :transferred_at
      drop_column :last_renewed_at
      drop_column :auto_renew
      drop_column :nameservers
      drop_column :contact_profile_id
    end

    drop_table(:domain_order)
    drop_table(:domain_tld)
    drop_table(:domain_contact_profile)
  end
end
