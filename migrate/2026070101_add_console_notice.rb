# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:console_notice) do
      primary_key :id
      column :enabled, TrueClass, null: false, default: false
      column :severity, String, null: false, default: "maintenance", collate: '"C"'
      column :title, String, null: false, default: "Upcoming maintenance"
      column :body, String, null: false, default: ""
      column :link_label, String, collate: '"C"'
      column :link_url, String, collate: '"C"'
      column :starts_at, :timestamptz
      column :ends_at, :timestamptz
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:valid_console_notice_severity, Sequel.lit("severity IN ('info', 'maintenance', 'warning', 'incident')"))
      constraint(:valid_console_notice_window) do
        (ends_at =~ nil) | (starts_at =~ nil) | (ends_at > starts_at)
      end
    end

    from(:console_notice).insert(
      enabled: false,
      severity: "maintenance",
      title: "Upcoming maintenance",
      body: "",
      created_at: Sequel::CURRENT_TIMESTAMP,
      updated_at: Sequel::CURRENT_TIMESTAMP
    )
  end

  down do
    drop_table(:console_notice)
  end
end
