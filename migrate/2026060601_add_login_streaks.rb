# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:accounts) do
      add_column :login_streak, Integer, null: false, default: 0
      add_column :login_streak_longest, Integer, null: false, default: 0
      add_column :login_streak_last_seen_on, Date
    end

    run <<~SQL
      ALTER TABLE accounts
        ADD CONSTRAINT valid_login_streak_non_negative
        CHECK (login_streak >= 0);

      ALTER TABLE accounts
        ADD CONSTRAINT valid_login_streak_longest_non_negative
        CHECK (login_streak_longest >= 0);
    SQL
  end

  down do
    alter_table(:accounts) do
      drop_constraint :valid_login_streak_non_negative
      drop_constraint :valid_login_streak_longest_non_negative
      drop_column :login_streak
      drop_column :login_streak_longest
      drop_column :login_streak_last_seen_on
    end
  end
end
