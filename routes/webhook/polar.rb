# frozen_string_literal: true

require "base64"

class Clover
  POLAR_WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS = 5 * 60

  hash_branch(:webhook_prefix, "polar") do |r|
    r.post true do
      body = r.body.read
      next 503 unless Config.polar_webhook_secret
      next 401 unless check_polar_signature(r.headers, body)

      response.content_type = :json
      event = JSON.parse(body)
      handle_polar_webhook(event)
    rescue JSON::ParserError
      response.status = 400
      {error: {message: "Invalid JSON"}}
    end
  end

  def handle_polar_webhook(event)
    data = event["data"] || {}
    checkout_id = data["checkout_id"] || data["checkoutId"] || data.dig("checkout", "id") || data["id"]
    kind = (data["metadata"] || {})["kind"] || (event["metadata"] || {})["kind"]
    return {message: "Polar webhook ignored", event: event["type"]} unless checkout_id && kind == "domain_checkout"

    result = DomainCheckout.reconcile!(checkout_id)
    Clog.emit("polar domain checkout webhook received", {polar_domain_checkout_webhook: {event_type: event["type"], checkout_id:, result:}})
    {message: "Polar domain checkout webhook received", event: event["type"], result:}
  rescue PolarAPIError => ex
    response.status = 502
    {error: {message: ex.message}}
  end

  def check_polar_signature(headers, body)
    message_id = headers["webhook-id"] || headers["svix-id"]
    timestamp = headers["webhook-timestamp"] || headers["svix-timestamp"]
    signature = headers["webhook-signature"] || headers["svix-signature"]
    return false unless message_id && timestamp && signature
    return false unless polar_webhook_timestamp_valid?(timestamp)

    signed_content = "#{message_id}.#{timestamp}.#{body}"
    expected_signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest("sha256", polar_webhook_secret_bytes, signed_content)
    )

    signature.split.any? do |candidate|
      version, actual_signature = candidate.split(",", 2)
      next false unless version == "v1" && actual_signature
      next false unless actual_signature.bytesize == expected_signature.bytesize

      Rack::Utils.secure_compare(actual_signature, expected_signature)
    end
  rescue ArgumentError
    false
  end

  def polar_webhook_timestamp_valid?(timestamp)
    timestamp = Integer(timestamp, 10)
    (Time.now.to_i - timestamp).abs <= POLAR_WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS
  rescue ArgumentError
    false
  end

  def polar_webhook_secret_bytes
    secret = Config.polar_webhook_secret.delete_prefix("whsec_")
    secret += "=" * ((4 - secret.length % 4) % 4)
    Base64.strict_decode64(secret)
  end
end
