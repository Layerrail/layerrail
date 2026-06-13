# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AzureClient do
  it "uses a disk-supported API version when deleting managed disks" do
    client = described_class.new(
      subscription_id: "sub",
      tenant_id: "tenant",
      client_id: "client",
      client_secret: "secret"
    )

    expect(client).to receive(:request).with(
      :delete,
      "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/disks/disk-1",
      api_version: "2024-03-02",
      expected_status: [200, 202, 204, 404]
    )

    client.delete_disk("rg", "disk-1")
  end
end
