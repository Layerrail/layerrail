# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO billing_record (id, project_id, resource_id, resource_name, amount, billing_rate_id, resource_tags)
      SELECT
        gen_random_uuid(),
        object_bucket.project_id,
        object_bucket.id,
        object_bucket.name,
        1,
        '72ef0ec2-cd86-4c2d-9f1a-d2045cff92ba',
        jsonb_build_object('service', 'object-bucket', 'bucket_name', object_bucket.bucket_name)
      FROM object_bucket
      WHERE object_bucket.state = 'ready'
        AND NOT EXISTS (
          SELECT 1
          FROM billing_record
          WHERE billing_record.resource_id = object_bucket.id
            AND billing_record.billing_rate_id = '72ef0ec2-cd86-4c2d-9f1a-d2045cff92ba'
            AND upper(billing_record.span) IS NULL
        )
    SQL

    run <<~SQL
      INSERT INTO billing_record (id, project_id, resource_id, resource_name, amount, billing_rate_id, resource_tags)
      SELECT
        gen_random_uuid(),
        vm.project_id,
        vm_backup_policy.id,
        vm.name || ' backups',
        SUM(vm_backup_snapshot.size_gib),
        '0d7fe1f1-29e5-4efb-b146-80e91f2f315d',
        jsonb_build_object('service', 'vm-backup', 'vm_id', vm.id)
      FROM vm_backup_policy
      JOIN vm ON vm.id = vm_backup_policy.vm_id
      JOIN vm_backup_snapshot ON vm_backup_snapshot.vm_backup_policy_id = vm_backup_policy.id
      WHERE vm_backup_snapshot.state = 'available'
      GROUP BY vm_backup_policy.id, vm.project_id, vm.name, vm.id
      HAVING SUM(vm_backup_snapshot.size_gib) > 0
        AND NOT EXISTS (
          SELECT 1
          FROM billing_record
          WHERE billing_record.resource_id = vm_backup_policy.id
            AND billing_record.billing_rate_id = '0d7fe1f1-29e5-4efb-b146-80e91f2f315d'
            AND upper(billing_record.span) IS NULL
        )
    SQL
  end

  down do
    run <<~SQL
      UPDATE billing_record
      SET span = tstzrange(lower(span), now())
      WHERE billing_rate_id IN (
        '72ef0ec2-cd86-4c2d-9f1a-d2045cff92ba',
        '0d7fe1f1-29e5-4efb-b146-80e91f2f315d'
      )
        AND upper(span) IS NULL
        AND resource_tags->>'service' IN ('object-bucket', 'vm-backup')
    SQL
  end
end
