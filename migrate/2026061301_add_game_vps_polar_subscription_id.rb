# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:game_vps) do
      add_column :polar_subscription_id, String, collate: '"C"'
      add_index :polar_subscription_id
    end
  end

  down do
    alter_table(:game_vps) do
      drop_index :polar_subscription_id
      drop_column :polar_subscription_id
    end
  end
end
