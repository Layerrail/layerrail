# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('azure') ON CONFLICT DO NOTHING;"
    alter_table(:game_vps) do
      set_column_default :provider, "azure"
    end
  end

  down do
    alter_table(:game_vps) do
      set_column_default :provider, "ionos"
    end
  end
end
