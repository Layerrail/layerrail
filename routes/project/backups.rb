# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "backups") do |r|
    r.web do
      authorize("Project:view", @project)

      r.get true do
        @postgres_backups = []
        if Config.postgres_enabled
          @postgres_backups = @project.postgres_resources_dataset.eager(:location, :timeline).all.map do |pg|
            timeline = pg.timeline
            backups = timeline&.backups || []
            earliest_restore_time = timeline&.earliest_restore_time
            latest_restore_time = timeline&.latest_restore_time

            {
              resource: pg,
              name: pg.name,
              type: "PostgreSQL",
              location: pg.display_location,
              state: pg.display_state,
              protected: earliest_restore_time && latest_restore_time && latest_restore_time > earliest_restore_time,
              count: backups.count,
              earliest_restore_time:,
              latest_restore_time:,
              path: "#{path(pg)}/backup-restore"
            }
          rescue => ex
            Clog.emit("postgres backup dashboard fetch failed", Util.exception_to_hash(ex).merge(postgres_id: pg.id))
            {
              resource: pg,
              name: pg.name,
              type: "PostgreSQL",
              location: pg.display_location,
              state: pg.display_state,
              protected: false,
              count: 0,
              error: "Backup status is temporarily unavailable.",
              path: path(pg)
            }
          end
        end

        @kubernetes_backups = []
        if Config.kubernetes_enabled
          @kubernetes_backups = @project.kubernetes_clusters_dataset.eager(:location, :kubernetes_etcd_backup).all.map do |cluster|
            backup = cluster.kubernetes_etcd_backup
            snapshots = backup&.backups || []

            {
              resource: cluster,
              name: cluster.name,
              type: "Kubernetes etcd",
              location: cluster.display_location,
              state: cluster.display_state,
              protected: !backup.nil?,
              count: snapshots.count,
              latest_backup_started_at: backup&.latest_backup_started_at,
              next_backup_time: backup&.next_backup_time,
              path: path(cluster)
            }
          rescue => ex
            Clog.emit("kubernetes backup dashboard fetch failed", Util.exception_to_hash(ex).merge(kubernetes_cluster_id: cluster.id))
            {
              resource: cluster,
              name: cluster.name,
              type: "Kubernetes etcd",
              location: cluster.display_location,
              state: cluster.display_state,
              protected: false,
              count: 0,
              error: "Backup status is temporarily unavailable.",
              path: path(cluster)
            }
          end
        end

        @vm_backup_count = @project.vms_dataset.count
        @backup_rows = @postgres_backups + @kubernetes_backups
        view "project/backups"
      end
    end
  end
end
