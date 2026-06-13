# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      ALTER TABLE domain_tld
        DROP CONSTRAINT IF EXISTS valid_domain_tld_provider;

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_provider
        CHECK (provider IN ('namesilo', 'domainnameapi', 'centralnic', 'openprovider'));

      ALTER TABLE domain_tld
        DROP CONSTRAINT IF EXISTS valid_domain_tld_name;

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_name
        CHECK (tld ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$');
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM domain_tld
      WHERE tld LIKE '%.%' OR provider <> 'namesilo';

      ALTER TABLE domain_tld
        DROP CONSTRAINT IF EXISTS valid_domain_tld_provider;

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_provider
        CHECK (provider = 'namesilo');

      ALTER TABLE domain_tld
        DROP CONSTRAINT IF EXISTS valid_domain_tld_name;

      ALTER TABLE domain_tld
        ADD CONSTRAINT valid_domain_tld_name
        CHECK (tld ~ '^[a-z0-9][a-z0-9-]{1,62}$');
    SQL
  end
end
