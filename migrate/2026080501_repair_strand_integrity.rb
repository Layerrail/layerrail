# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    repair_sql = <<~SQL
      -- Prefer an active copy so an exited duplicate cannot discard unfinished
      -- work, then keep the copy that was most recently leased or scheduled.
      -- ctid is only a deterministic final tie-breaker while the table is locked.
      CREATE TEMP TABLE strand_integrity_winner ON COMMIT DROP AS
      SELECT id, ctid AS winner_ctid, earliest_schedule, duplicate_count
      FROM (
        SELECT
          id,
          ctid,
          min(schedule) OVER (PARTITION BY id) AS earliest_schedule,
          count(*) OVER (PARTITION BY id) AS duplicate_count,
          row_number() OVER (
            PARTITION BY id
            ORDER BY
              (exitval IS NULL) DESC,
              lease DESC NULLS LAST,
              schedule DESC,
              try DESC,
              ctid DESC
          ) AS winner_rank
        FROM strand
      ) ranked
      WHERE winner_rank = 1;

      DELETE FROM strand AS duplicate
      USING strand_integrity_winner AS winner
      WHERE duplicate.id = winner.id
        AND duplicate.ctid <> winner.winner_ctid;

      -- Preserve the earliest wakeup across all copies and make every repaired
      -- strand immediately leasable without retaining duplicate retry backoff.
      UPDATE strand AS repaired
      SET schedule = winner.earliest_schedule,
          lease = now() - '1000 years'::interval,
          try = 0
      FROM strand_integrity_winner AS winner
      WHERE repaired.id = winner.id
        AND winner.duplicate_count > 1;

      -- A restore that omitted the primary key may also have omitted the two
      -- foreign keys that normally prevent these orphaned references.
      DELETE FROM semaphore AS orphan
      WHERE NOT EXISTS (
        SELECT 1
        FROM strand
        WHERE strand.id = orphan.strand_id
      );

      UPDATE strand AS orphan
      SET parent_id = NULL
      WHERE orphan.parent_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1
          FROM strand AS parent
          WHERE parent.id = orphan.parent_id
        );

      DO $$
      DECLARE
        primary_key_name text;
      BEGIN
        -- A primary-key constraint can exist while its backing index is invalid,
        -- so verify both catalog records before deciding the table is healthy.
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint AS constraint_record
          JOIN pg_index AS index_record
            ON index_record.indexrelid = constraint_record.conindid
          WHERE constraint_record.conrelid = 'strand'::regclass
            AND constraint_record.contype = 'p'
            AND constraint_record.convalidated
            AND index_record.indisvalid
            AND index_record.indisunique
        ) THEN
          FOR primary_key_name IN
            SELECT constraint_record.conname
            FROM pg_constraint AS constraint_record
            WHERE constraint_record.conrelid = 'strand'::regclass
              AND constraint_record.contype = 'p'
          LOOP
            EXECUTE format('ALTER TABLE strand DROP CONSTRAINT %I CASCADE', primary_key_name);
          END LOOP;

          DROP INDEX IF EXISTS strand_pkey;
          ALTER TABLE strand ADD CONSTRAINT strand_pkey PRIMARY KEY (id);
        END IF;
      END
      $$;

      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint
          WHERE conrelid = 'strand'::regclass
            AND conname = 'strand_parent_id_fkey'
            AND contype = 'f'
        ) THEN
          ALTER TABLE strand
            ADD CONSTRAINT strand_parent_id_fkey
            FOREIGN KEY (parent_id) REFERENCES strand(id);
        ELSE
          ALTER TABLE strand VALIDATE CONSTRAINT strand_parent_id_fkey;
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint
          WHERE conrelid = 'semaphore'::regclass
            AND conname = 'semaphore_strand_id_fkey'
            AND contype = 'f'
        ) THEN
          ALTER TABLE semaphore
            ADD CONSTRAINT semaphore_strand_id_fkey
            FOREIGN KEY (strand_id) REFERENCES strand(id);
        ELSE
          ALTER TABLE semaphore VALIDATE CONSTRAINT semaphore_strand_id_fkey;
        END IF;
      END
      $$;

      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM strand
          GROUP BY id
          HAVING count(*) <> 1
        ) THEN
          RAISE EXCEPTION 'strand integrity repair left duplicate IDs';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint AS constraint_record
          JOIN pg_index AS index_record
            ON index_record.indexrelid = constraint_record.conindid
          WHERE constraint_record.conrelid = 'strand'::regclass
            AND constraint_record.contype = 'p'
            AND constraint_record.convalidated
            AND index_record.indisvalid
            AND index_record.indisunique
        ) THEN
          RAISE EXCEPTION 'strand integrity repair did not restore a valid primary key';
        END IF;
      END
      $$;
    SQL

    lock_attempt = 0

    begin
      transaction do
        run "LOCK TABLE strand, semaphore IN ACCESS EXCLUSIVE MODE NOWAIT"
        run repair_sql
      end
    rescue Sequel::DatabaseLockTimeout, Sequel::SerializationFailure => error
      lock_attempt += 1
      raise if lock_attempt >= 300

      if lock_attempt == 1 || (lock_attempt % 20).zero?
        warn "Strand integrity repair waiting for active workers (attempt #{lock_attempt}/300, #{error.class})"
      end

      sleep(0.2 + rand * 0.8)
      retry
    end
  end

  down do
    # Data deduplication and constraint restoration are intentionally irreversible.
  end
end
