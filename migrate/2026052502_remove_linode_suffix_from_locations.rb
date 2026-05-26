# frozen_string_literal: true

Sequel.migration do
  up do
    from(:location).where(provider: "linode").each do |loc|
      new_ui_name = loc[:ui_name].sub(/\s*\(Linode\)$/, "")
      from(:location).where(id: loc[:id]).update(ui_name: new_ui_name)
    end
  end

  down do
    from(:location).where(provider: "linode", name: "linode-de-fra-2").update(ui_name: "Frankfurt, DE (Linode)")
    from(:location).where(provider: "linode", name: "linode-us-east").update(ui_name: "Newark, NJ (Linode)")
    from(:location).where(provider: "linode", name: "linode-us-lax").update(ui_name: "Los Angeles, CA (Linode)")
    from(:location).where(provider: "linode", name: "linode-us-sea").update(ui_name: "Seattle, WA (Linode)")
  end
end
