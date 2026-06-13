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
    checkout_id = polar_checkout_id(event)
    kind = (data["metadata"] || {})["kind"] || (event["metadata"] || {})["kind"]
    return {message: "Polar webhook ignored", event: event["type"]} unless checkout_id

    case kind
    when "domain_checkout"
      result = DomainCheckout.reconcile!(checkout_id)
      Clog.emit("polar domain checkout webhook received", {polar_domain_checkout_webhook: {event_type: event["type"], checkout_id:, result:}})
      {message: "Polar domain checkout webhook received", event: event["type"], result:}
    when "game_vps_checkout"
      result = GameVpsCheckout.reconcile!(checkout_id)
      Clog.emit("polar game vps checkout webhook received", {polar_game_vps_checkout_webhook: {event_type: event["type"], checkout_id:, result:}})
      {message: "Polar game vps checkout webhook received", event: event["type"], result:}
    else
      {message: "Polar webhook ignored", event: event["type"]}
    end
  rescue PolarAPIError => ex
    Clog.emit("polar webhook reconciliation failed", {polar_webhook_reconciliation_failed: {event_type: event["type"], checkout_id:, error_class: ex.class.name, error_message: ex.message}})
    {message: "Polar webhook accepted; reconciliation will be retried from browser return or admin retry", event: event["type"]}
  rescue => ex
    Clog.emit("polar webhook failed", Util.exception_to_hash(ex, into: {polar_webhook_failed: {event_type: event["type"], checkout_id:}}))
    {message: "Polar webhook accepted; internal error recorded", event: event["type"]}
  end

  def polar_checkout_id(event)
    data = event["data"] || {}
    checkout_id =
      data["checkout_id"] ||
      data["checkoutId"] ||
      data.dig("checkout", "id") ||
      data.dig("order", "checkout_id") ||
      data.dig("order", "checkoutId") ||
      data.dig("metadata", "checkout_id") ||
      event.dig("metadata", "checkout_id")

    checkout_id ||= data["id"] if event["type"].to_s.start_with?("checkout.")
    checkout_id = checkout_id.to_s.strip
    checkout_id.empty? ? nil : checkout_id
  end

  def check_polar_signature(headers, body)
    message_id = headers["webhook-id"] || headers["svix-id"]
    timestamp = headers["webhook-timestamp"] || headers["svix-timestamp"]
    signature = headers["webhook-signature"] || headers["svix-signature"]
    return false unless message_id && timestamp && signature
    return false unless polar_webhook_timestamp_valid?(timestamp)

    signed_content = "#{message_id}.#{timestamp}.#{body}"
    expected_signatures = polar_webhook_secret_candidates.map do |secret|
      Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, signed_content))
    end

    signature.split.any? do |candidate|
      version, actual_signature = candidate.split(",", 2)
      next false unless version == "v1" && actual_signature

      expected_signatures.any? do |expected_signature|
        actual_signature.bytesize == expected_signature.bytesize &&
          Rack::Utils.secure_compare(actual_signature, expected_signature)
      end
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

  def polar_webhook_secret_candidates
    secret = Config.polar_webhook_secret.to_s
    candidates = [secret]
    encoded_secret = secret.delete_prefix("whsec_")
    padded_secret = encoded_secret + ("=" * ((4 - encoded_secret.length % 4) % 4))
    candidates << Base64.strict_decode64(padded_secret)
    candidates.uniq
  rescue ArgumentError
    candidates
  end
end
