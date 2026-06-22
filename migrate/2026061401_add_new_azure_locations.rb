# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id)
      VALUES
        ('azure', 'azure-southafricanorth', 'azure-southafricanorth', 'South Africa North', true, gen_random_uuid()),
        ('azure', 'azure-uksouth', 'azure-uksouth', 'UK South', true, gen_random_uuid())
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    from(:location)
      .where(provider: "azure", name: ["azure-southafricanorth", "azure-uksouth"])
      .delete
  end
end
