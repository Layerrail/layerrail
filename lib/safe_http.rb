# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "openssl"
require "socket"
require "uri"

class SafeHttp
  class UnsafeUrl < StandardError; end
  class ResponseTooLarge < StandardError; end

  MAX_URL_BYTES = 2048
  BLOCKED_HOST_SUFFIXES = %w[localhost local internal home.arpa].freeze
  BLOCKED_NETWORKS = %w[
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.88.99.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    240.0.0.0/4
    ::/128
    ::1/128
    64:ff9b::/96
    64:ff9b:1::/48
    100::/64
    2001::/23
    2001:db8::/32
    2002::/16
    3fff::/20
    fc00::/7
    fe80::/10
    fec0::/10
    ff00::/8
  ].map { IPAddr.new(it) }.freeze

  def self.validate_url!(url, allowed_schemes: %w[https], allow_query: true)
    uri, = parse_and_resolve(url, allowed_schemes:, allow_query:)
    uri
  end

  def self.start(url, allowed_schemes: %w[https], allow_query: true, open_timeout: 5, read_timeout: 10, write_timeout: 10)
    uri, addresses = parse_and_resolve(url, allowed_schemes:, allow_query:)
    http = Net::HTTP.new(uri.hostname, uri.port, nil)
    http.ipaddr = addresses.first
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout
    http.write_timeout = write_timeout if http.respond_to?(:write_timeout=)
    http.start { yield http }
  end

  def self.parse_and_resolve(url, allowed_schemes:, allow_query:)
    raw = url.is_a?(URI::Generic) ? url.to_s : String(url)
    raise UnsafeUrl, "is too long" if raw.bytesize > MAX_URL_BYTES

    uri = URI.parse(raw)
    raise UnsafeUrl, "must use #{allowed_schemes.join(" or ")}" unless uri.is_a?(URI::HTTP) && allowed_schemes.include?(uri.scheme)
    raise UnsafeUrl, "must include a host" if uri.host.to_s.empty?
    raise UnsafeUrl, "must not include credentials" if uri.userinfo
    raise UnsafeUrl, "must not include a fragment" if uri.fragment
    raise UnsafeUrl, "must not include a query string" if !allow_query && uri.query

    [uri, public_addresses(uri.hostname)]
  rescue URI::InvalidURIError, ArgumentError
    raise UnsafeUrl, "is invalid"
  end
  private_class_method :parse_and_resolve

  def self.public_addresses(host)
    normalized_host = host.downcase.delete_suffix(".")
    if BLOCKED_HOST_SUFFIXES.any? { normalized_host == it || normalized_host.end_with?(".#{it}") } || normalized_host.include?("%")
      raise UnsafeUrl, "must resolve only to public IP addresses"
    end

    addresses = Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq.map { IPAddr.new(it) }
    raise UnsafeUrl, "host could not be resolved" if addresses.empty?
    raise UnsafeUrl, "must resolve only to public IP addresses" if addresses.any? { blocked_address?(it) }

    addresses.sort_by { it.ipv4? ? 0 : 1 }.map(&:to_s)
  rescue SocketError
    raise UnsafeUrl, "host could not be resolved"
  end
  private_class_method :public_addresses

  def self.blocked_address?(address)
    address = address.native if address.ipv4_mapped?
    BLOCKED_NETWORKS.any? { it.ipv4? == address.ipv4? && it.include?(address) }
  end
  private_class_method :blocked_address?
end
