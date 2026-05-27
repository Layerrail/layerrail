# frozen_string_literal: true

require "base64"

class Clover
  RESEND_WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS = 5 * 60

  hash_branch(:webhook_prefix, "resend") do |r|
    r.post true do
      body = r.body.read
      next 503 unless Config.resend_webhook_secret
      next 401 unless check_resend_signature(r.headers, body)

      response.content_type = :json

      event = JSON.parse(body)
      handle_resend_webhook(event, r.headers["svix-id"])
    rescue JSON::ParserError
      response.status = 400
      {error: {message: "Invalid JSON"}}
    end
  end

  def handle_resend_webhook(event, message_id)
    data = event["data"] || {}
    summary = {
      message_id:,
      event_type: event["type"],
      email_id: data["email_id"] || data["id"],
      to: data["to"],
      created_at: event["created_at"] || data["created_at"]
    }.compact

    Clog.emit("resend webhook received", {resend_webhook: summary})

    {message: "Resend webhook received", event: event["type"]}
  end

  def check_resend_signature(headers, body)
    message_id = headers["svix-id"]
    timestamp = headers["svix-timestamp"]
    signature = headers["svix-signature"]
    return false unless message_id && timestamp && signature
    return false unless resend_webhook_timestamp_valid?(timestamp)

    signed_content = "#{message_id}.#{timestamp}.#{body}"
    expected_signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest("sha256", resend_webhook_secret_bytes, signed_content)
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

  def resend_webhook_timestamp_valid?(timestamp)
    timestamp = Integer(timestamp, 10)
    (Time.now.to_i - timestamp).abs <= RESEND_WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS
  rescue ArgumentError
    false
  end

  def resend_webhook_secret_bytes
    secret = Config.resend_webhook_secret.delete_prefix("whsec_")
    secret += "=" * ((4 - secret.length % 4) % 4)
    Base64.strict_decode64(secret)
  end
end
