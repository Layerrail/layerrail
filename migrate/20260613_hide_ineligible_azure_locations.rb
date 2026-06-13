# frozen_string_literal: true

Sequel.migration do
  up do
    from(:location)
      .where(provider: "azure", name: ["azure-westeurope", "azure-northeurope"])
      .update(visible: false)
  end

  down do
    from(:location)
      .where(provider: "azure", name: ["azure-westeurope", "azure-northeurope"])
      .update(visible: true)
  end
end
