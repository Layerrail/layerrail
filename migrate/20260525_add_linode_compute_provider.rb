# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('linode') ON CONFLICT DO NOTHING;"

    create_table(:private_subnet_linode_resource) do
      foreign_key :id, :private_subnet, type: :uuid, primary_key: true, on_delete: :cascade
      column :firewall_id, Integer, null: false, unique: true
    end

    create_table(:linode_instance) do
      foreign_key :id, :vm, type: :uuid, primary_key: true, on_delete: :cascade
      column :linode_id, Integer, null: false, unique: true
      column :region, String, null: false, collate: '"C"'
      column :linode_type, String, null: false, collate: '"C"'
      column :image, String, null: false, collate: '"C"'
      column :label, String, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        ('linode', 'linode-de-fra-2', 'linode-de-fra-2', 'Frankfurt, DE (Linode)', true, 'd0bbeb96-f263-4bfc-9bfc-14359a325294'),
        ('linode', 'linode-us-east', 'linode-us-east', 'Newark, NJ (Linode)', true, '179fdc1f-68cc-4df1-ab1f-978405083459'),
        ('linode', 'linode-us-lax', 'linode-us-lax', 'Los Angeles, CA (Linode)', true, '176ce9fa-219d-4d1b-8d1c-b6f9f6914a5c'),
        ('linode', 'linode-us-sea', 'linode-us-sea', 'Seattle, WA (Linode)', true, '69eeb600-7448-441f-9420-a628cd92b547')
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    from(:location).where(provider: "linode").delete
    drop_table(:linode_instance)
    drop_table(:private_subnet_linode_resource)
    from(:provider).where(name: "linode").delete
  end
end
