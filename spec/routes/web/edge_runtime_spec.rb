# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "Edge runtime" do
  let(:project) { Project.create(name: "edge-security") }
  let(:public_address) { instance_double(Addrinfo, ip_address: "93.184.216.34") }
  let!(:edge_service) do
    EdgeService.create(
      project_id: project.id,
      name: "private-origin",
      hostname: "private-origin.edge.layerrail.com",
      origin_url: "http://127.0.0.1:3000/ready",
      cache_mode: "standard",
      tls_mode: "strict",
      state: "ready",
    )
  end

  it "does not expose an unsafe origin through the resolver" do
    expect(Net::HTTP).not_to receive(:new)

    page.driver.get("/edge-runtime/resolve?host=#{edge_service.hostname}")

    expect(page.status_code).to eq(404)
    expect(page.body).not_to include("127.0.0.1")
  end

  it "does not proxy an unsafe origin" do
    expect(Net::HTTP).not_to receive(:new)

    page.driver.get("/", {}, {"HTTP_HOST" => edge_service.hostname})

    expect(page.status_code).to eq(404)
    expect(page.body).to eq("Edge service not found\n")
  end

  it "proxies a validated public origin with trusted forwarding headers" do
    public_service = EdgeService.create(
      project_id: project.id,
      name: "public-origin",
      hostname: "public-origin.edge.layerrail.com",
      origin_url: "https://origin.example/base",
      cache_mode: "standard",
      tls_mode: "strict",
      state: "ready",
    )
    allow(Addrinfo).to receive(:getaddrinfo).with("origin.example", nil, nil, :STREAM).and_return([public_address])
    upstream = instance_double(Net::HTTPResponse, code: "200")
    allow(upstream).to receive(:[]).and_return(nil)
    allow(upstream).to receive(:[]).with("content-length").and_return("2")
    allow(upstream).to receive(:read_body).and_yield("ok")
    allow(upstream).to receive(:each_header).and_yield("content-type", "text/plain")
    http = instance_double(Net::HTTP)
    expect(SafeHttp).to receive(:start).with(
      instance_of(URI::HTTPS),
      allowed_schemes: %w[http https],
      open_timeout: 10,
      read_timeout: 60,
    ).and_yield(http)
    expect(http).to receive(:request) do |proxy_request, &block|
      expect(proxy_request).to be_a(Net::HTTP::Get)
      expect(proxy_request.path).to eq("/base/")
      expect(proxy_request["X-Forwarded-For"]).to eq("5.6.7.8")
      expect(proxy_request["X-Layerrail-Edge"]).to eq("control-plane")
      expect(proxy_request["Proxy-Authorization"]).to be_nil
      expect(proxy_request["X-Remove-Me"]).to be_nil
      block.call(upstream)
    end

    page.driver.get("/", {}, {
      "HTTP_HOST" => public_service.hostname,
      "HTTP_CONNECTION" => "keep-alive, X-Remove-Me",
      "HTTP_PROXY_AUTHORIZATION" => "attacker-controlled",
      "HTTP_X_REMOVE_ME" => "attacker-controlled",
      "HTTP_X_FORWARDED_FOR" => "attacker-controlled",
      "REMOTE_ADDR" => "5.6.7.8",
    })

    expect(page.status_code).to eq(200)
    expect(page.body).to eq("ok")
    expect(page.response_headers["content-type"]).to eq("text/plain")
    expect(page.response_headers).not_to include("cache-control", "cross-origin-resource-policy")
  end
end
