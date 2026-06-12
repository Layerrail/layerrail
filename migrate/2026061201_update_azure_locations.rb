# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE location
      SET visible = false
      WHERE provider = 'azure' AND name = 'azure-westus3';

      INSERT INTO location (provider, display_name, name, ui_name, visible, id)
      VALUES ('azure', 'azure-eastus2', 'azure-eastus2', 'East US 2', true, '4e30ddb2-fe0e-4cad-92bf-05402ba14e10')
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    from(:location).where(provider: "azure", name: "azure-eastus2").delete
    from(:location).where(provider: "azure", name: "azure-westus3").update(visible: true)
  end
end
