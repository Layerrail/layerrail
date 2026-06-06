# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      ALTER TABLE accounts
        ADD COLUMN IF NOT EXISTS login_streak integer NOT NULL DEFAULT 0;

      ALTER TABLE accounts
        ADD COLUMN IF NOT EXISTS login_streak_longest integer NOT NULL DEFAULT 0;

      ALTER TABLE accounts
        ADD COLUMN IF NOT EXISTS login_streak_last_seen_on date;

      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM information_schema.table_constraints
          WHERE table_schema = 'public'
            AND table_name = 'accounts'
            AND constraint_name = 'valid_login_streak_non_negative'
        ) THEN
          ALTER TABLE accounts
            ADD CONSTRAINT valid_login_streak_non_negative
            CHECK (login_streak >= 0);
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM information_schema.table_constraints
          WHERE table_schema = 'public'
            AND table_name = 'accounts'
            AND constraint_name = 'valid_login_streak_longest_non_negative'
        ) THEN
          ALTER TABLE accounts
            ADD CONSTRAINT valid_login_streak_longest_non_negative
            CHECK (login_streak_longest >= 0);
        END IF;
      END $$;
    SQL
  end

  down do
    run <<~SQL
      ALTER TABLE accounts
        DROP CONSTRAINT IF EXISTS valid_login_streak_non_negative;

      ALTER TABLE accounts
        DROP CONSTRAINT IF EXISTS valid_login_streak_longest_non_negative;

      ALTER TABLE accounts
        DROP COLUMN IF EXISTS login_streak;

      ALTER TABLE accounts
        DROP COLUMN IF EXISTS login_streak_longest;

      ALTER TABLE accounts
        DROP COLUMN IF EXISTS login_streak_last_seen_on;
    SQL
  end
end
