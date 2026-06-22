# frozen_string_literal: true

# Azure West Europe and North Europe are permanently ineligible for new
# customer resource provisioning (RequestDisallowedByAzure). Hide them
# from all user-facing location pickers so no new resources can be
# created there.

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
