# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('linode') ON CONFLICT DO NOTHING;"

    from(:location).where(provider: "linode").exclude(name: [
      "linode-de-fra-2",
      "linode-us-east",
      "linode-us-lax",
      "linode-us-sea",
    ]).update(visible: false)

    run <<~SQL
      INSERT INTO location (id, provider, display_name, name, ui_name, visible) VALUES
        ('d0bbeb96-f263-4bfc-9bfc-14359a325294', 'linode', 'linode-de-fra-2', 'linode-de-fra-2', 'Frankfurt, DE (Linode)', true),
        ('179fdc1f-68cc-4df1-ab1f-978405083459', 'linode', 'linode-us-east', 'linode-us-east', 'Newark, NJ (Linode)', true),
        ('176ce9fa-219d-4d1b-8d1c-b6f9f6914a5c', 'linode', 'linode-us-lax', 'linode-us-lax', 'Los Angeles, CA (Linode)', true),
        ('69eeb600-7448-441f-9420-a628cd92b547', 'linode', 'linode-us-sea', 'linode-us-sea', 'Seattle, WA (Linode)', true)
      ON CONFLICT (id) DO UPDATE SET
        display_name = EXCLUDED.display_name,
        name = EXCLUDED.name,
        ui_name = EXCLUDED.ui_name,
        visible = EXCLUDED.visible;
    SQL
  end

  down do
    from(:location).where(name: ["linode-de-fra-2", "linode-us-lax", "linode-us-sea"]).update(visible: false)
    from(:location).where(name: "linode-us-east").update(ui_name: "Newark, US (Linode)", visible: true)
    from(:location).where(name: "linode-eu-west").update(visible: true)
  end
end
