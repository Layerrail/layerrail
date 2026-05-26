# frozen_string_literal: true

RSpec.describe LinodeClient do
  let(:client) { described_class.new(access_token: "linode-token", base_url: "https://api.linode.com/v4") }

  it "preserves the configured API path prefix" do
    request = stub_request(:post, "https://api.linode.com/v4/networking/firewalls/")
      .with(
        headers: {"Authorization" => "Bearer linode-token"},
        body: {
          label: "fw-test",
          rules: {inbound: [], outbound: []},
          tags: ["LayerRail"]
        }
      )
      .to_return(status: 200, body: JSON.generate({"id" => 123}))

    expect(client.create_firewall(label: "fw-test", rules: {inbound: [], outbound: []}, tags: ["LayerRail"])).to eq({"id" => 123})
    expect(request).to have_been_requested
  end

  it "wraps transport errors without assuming an HTTP response exists" do
    stub_request(:get, "https://api.linode.com/v4/linode/instances/123/")
      .to_raise(Excon::Error::Socket.new(StandardError.new("no address for api.linode.com")))

    expect {
      client.get_linode(123)
    }.to raise_error(LinodeAPIError) { |error|
      expect(error.status).to be_nil
      expect(error.body).to be_nil
    }
  end
end
