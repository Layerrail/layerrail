# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe SafeHttp, "integration" do
  let(:project) { Project.create(name: "outbound-security") }

  it "blocks an uptime check from contacting loopback" do
    check = UptimeCheck.create(
      project_id: project.id,
      name: "loopback",
      target_url: "http://127.0.0.1:3000/ready",
      interval_seconds: 60,
    )
    expect(Net::HTTP).not_to receive(:new)

    expect(check.run_check!).to be(false)
    expect(check.reload.last_error).to include("public IP addresses")
  end

  it "blocks a monitoring webhook from contacting cloud metadata" do
    channel = MonitoringNotificationChannel.create(
      project_id: project.id,
      name: "metadata",
      kind: "webhook",
      target: "https://169.254.169.254/latest/meta-data",
    )
    channel = MonitoringNotificationChannel.eager(:project).with_pk(channel.id)
    expect(Net::HTTP).not_to receive(:new)

    expect { channel.deliver_test! }.to raise_error(SafeHttp::UnsafeUrl, /public IP addresses/)
  end

  it "does not buffer an uptime response body" do
    check = UptimeCheck.create(
      project_id: project.id,
      name: "public",
      target_url: "https://example.com/health",
      interval_seconds: 60,
    )
    response = instance_double(Net::HTTPResponse, code: "200")
    http = instance_double(Net::HTTP)
    allow(described_class).to receive(:validate_url!).and_return(URI("https://example.com/health"))
    allow(described_class).to receive(:start).and_yield(http)
    expect(http).to receive(:request).with(instance_of(Net::HTTP::Get)).and_yield(response)
    expect(response).not_to receive(:body)

    result = check.run_check!
    expect(check.reload.last_error).to be_nil
    expect(result).to be(true)
  end

  it "does not buffer a webhook response body" do
    channel = MonitoringNotificationChannel.create(
      project_id: project.id,
      name: "public",
      kind: "webhook",
      target: "https://example.com/hook",
    )
    channel = MonitoringNotificationChannel.eager(:project).with_pk(channel.id)
    response = instance_double(Net::HTTPResponse, code: "204")
    http = instance_double(Net::HTTP)
    allow(described_class).to receive(:validate_url!).and_return(URI("https://example.com/hook"))
    allow(described_class).to receive(:start).and_yield(http)
    expect(http).to receive(:request).with(instance_of(Net::HTTP::Post)).and_yield(response)
    expect(response).not_to receive(:body)

    expect { channel.deliver_test! }.not_to raise_error
  end
end
