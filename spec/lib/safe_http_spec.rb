# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe SafeHttp do
  def address(ip)
    instance_double(Addrinfo, ip_address: ip)
  end

  it "accepts a public HTTPS URL" do
    allow(Addrinfo).to receive(:getaddrinfo).with("example.com", nil, nil, :STREAM).and_return([address("93.184.216.34")])

    expect(described_class.validate_url!("https://example.com/path?ok=1").to_s).to eq("https://example.com/path?ok=1")
  end

  it "requires HTTPS unless HTTP is explicitly allowed" do
    allow(Addrinfo).to receive(:getaddrinfo).with("example.com", nil, nil, :STREAM).and_return([address("93.184.216.34")])

    expect { described_class.validate_url!("http://example.com") }.to raise_error(described_class::UnsafeUrl, /must use https/)
    expect(described_class.validate_url!("http://example.com", allowed_schemes: %w[http https]).scheme).to eq("http")
  end

  it "rejects URL credentials, fragments, and disallowed queries" do
    allow(Addrinfo).to receive(:getaddrinfo).with("example.com", nil, nil, :STREAM).and_return([address("93.184.216.34")])

    expect { described_class.validate_url!("https://user:secret@example.com") }.to raise_error(described_class::UnsafeUrl, /credentials/)
    expect { described_class.validate_url!("https://example.com/#fragment") }.to raise_error(described_class::UnsafeUrl, /fragment/)
    expect { described_class.validate_url!("https://example.com/?token=secret", allow_query: false) }.to raise_error(described_class::UnsafeUrl, /query string/)
  end

  it "rejects loopback, private, link-local, metadata, and mapped addresses" do
    urls = [
      "http://127.0.0.1",
      "http://10.0.0.1",
      "http://169.254.169.254/latest/meta-data",
      "http://[::1]",
      "http://[::ffff:127.0.0.1]",
      "http://[fd00:ec2::254]",
      "http://[fec0::1]",
      "http://[2001:db8::1]",
      "http://[3fff::1]",
    ]

    urls.each do |url|
      expect { described_class.validate_url!(url, allowed_schemes: %w[http https]) }
        .to raise_error(described_class::UnsafeUrl, /public IP addresses/)
    end
  end

  it "rejects local hostnames without resolving them" do
    expect(Addrinfo).not_to receive(:getaddrinfo)

    expect { described_class.validate_url!("https://metadata.google.internal") }
      .to raise_error(described_class::UnsafeUrl, /public IP addresses/)
  end

  it "rejects DNS answers that mix public and private addresses" do
    allow(Addrinfo).to receive(:getaddrinfo).with("mixed.example", nil, nil, :STREAM)
      .and_return([address("93.184.216.34"), address("127.0.0.1")])

    expect { described_class.validate_url!("https://mixed.example") }
      .to raise_error(described_class::UnsafeUrl, /public IP addresses/)
  end

  it "pins the connection to the validated DNS answer" do
    allow(Addrinfo).to receive(:getaddrinfo).with("example.com", nil, nil, :STREAM).and_return([address("93.184.216.34")])
    http = Net::HTTP.new("example.com", 443, nil)
    expect(Net::HTTP).to receive(:new).with("example.com", 443, nil).and_return(http)
    expect(http).to receive(:ipaddr=).with("93.184.216.34").and_call_original
    expect(http).to receive(:start).and_yield

    expect(described_class.start("https://example.com") { |_client| :ok }).to eq(:ok)
  end
end
