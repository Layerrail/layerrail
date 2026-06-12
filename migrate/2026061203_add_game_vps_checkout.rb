# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:game_vps) do
      add_column :checkout_id, String, collate: '"C"'
      add_column :paid_until, :timestamptz
      add_column :subscription_amount_cents, Integer
      add_index :checkout_id
    end

    run "ALTER TABLE game_vps DROP CONSTRAINT IF EXISTS valid_game_vps_status;"
    run <<~SQL
      ALTER TABLE game_vps
        ADD CONSTRAINT valid_game_vps_status
        CHECK (status IN ('pending_payment', 'creating', 'running', 'failed', 'deleting', 'deleted'));
    SQL
  end

  down do
    run "ALTER TABLE game_vps DROP CONSTRAINT IF EXISTS valid_game_vps_status;"
    run <<~SQL
      ALTER TABLE game_vps
        ADD CONSTRAINT valid_game_vps_status
        CHECK (status IN ('creating', 'running', 'failed', 'deleting', 'deleted'));
    SQL

    alter_table(:game_vps) do
      drop_index :checkout_id
      drop_column :subscription_amount_cents
      drop_column :paid_until
      drop_column :checkout_id
    end
  end
end
