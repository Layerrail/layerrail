# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO strand (id, schedule, lease, prog, label, stack, try)
      SELECT
        gen_timestamp_ubid_uuid(826),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP - INTERVAL '1000 years',
        'InstallRhizome',
        'start',
        jsonb_build_array(jsonb_build_object(
          'subject_id', kubernetes_node.vm_id,
          'target_folder', 'kubernetes'
        )),
        0
      FROM kubernetes_node
      JOIN kubernetes_cluster ON kubernetes_cluster.id = kubernetes_node.kubernetes_cluster_id
      JOIN strand AS cluster_strand ON cluster_strand.id = kubernetes_cluster.id
      WHERE kubernetes_node.state = 'active'
        AND cluster_strand.exitval IS NULL
        AND cluster_strand.label <> 'destroy'
        AND NOT EXISTS (
          SELECT 1
          FROM semaphore
          WHERE semaphore.strand_id = kubernetes_cluster.id
            AND semaphore.name IN ('destroy', 'destroying')
        );

      WITH repair_targets AS (
        SELECT kubernetes_cluster.id
        FROM kubernetes_cluster
        JOIN strand ON strand.id = kubernetes_cluster.id
        WHERE strand.exitval IS NULL
          AND strand.label <> 'destroy'
          AND NOT EXISTS (
            SELECT 1
            FROM semaphore
            WHERE semaphore.strand_id = kubernetes_cluster.id
              AND semaphore.name IN ('destroy', 'destroying')
          )
          AND NOT EXISTS (
            SELECT 1
            FROM semaphore
            WHERE semaphore.strand_id = kubernetes_cluster.id
              AND semaphore.name = 'sync_pod_network'
          )
      ), inserted_repairs AS (
        INSERT INTO semaphore (id, strand_id, name)
        SELECT gen_timestamp_ubid_uuid(820), id, 'sync_pod_network'
        FROM repair_targets
        RETURNING strand_id
      )
      UPDATE strand
      SET schedule = CURRENT_TIMESTAMP
      WHERE id IN (SELECT strand_id FROM inserted_repairs);
    SQL
  end

  down do
    # Scheduling operational reconciliation is intentionally irreversible.
  end
end
