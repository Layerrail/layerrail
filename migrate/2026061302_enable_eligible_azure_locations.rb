# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id)
      VALUES ('azure', 'azure-centralus', 'azure-centralus', 'Central US', true, '195fb7e8-b350-47a8-bd5b-521bb5c1ab4e')
      ON CONFLICT DO NOTHING;
    SQL

    from(:location)
      .where(provider: "azure", name: ["azure-centralus", "azure-westeurope"])
      .update(visible: true)
  end

  down do
    from(:location)
      .where(provider: "azure", name: ["azure-centralus", "azure-westeurope"])
      .update(visible: false)
  end
end
