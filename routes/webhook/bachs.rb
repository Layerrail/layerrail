# frozen_string_literal: true

require "openssl"

class Clover
  BACHS_WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS = 5 * 60

  hash_branch(:webhook_prefix, "bachs") do |r|
    r.post true do
      body = r.body.read
      next 503 unless BachsClient.enabled? && Config.bachs_webhook_secret
      next 401 unless check_bachs_signature(r.headers, body)

      response.content_type = :json
      event = JSON.parse(body)
      result = BachsInvoiceCheckout.reconcile_event!(event)
      Clog.emit("Bachs webhook received", {bachs_webhook: {event_type: event["event_type"] || event["type"], result:}})
      {message: "Bachs webhook accepted", result:}
    rescue JSON::ParserError
      response.status = 400
      {error: {message: "Invalid JSON"}}
    rescue BachsAPIError => ex
      Clog.emit("Bachs webhook reconciliation failed", Util.exception_to_hash(ex, into: {bachs_webhook_reconciliation_failed: {}}))
      {message: "Bachs webhook accepted; reconciliation will be retried from the invoice payment return"}
    rescue => ex
      Clog.emit("Bachs webhook failed", Util.exception_to_hash(ex, into: {bachs_webhook_failed: {}}))
      {message: "Bachs webhook accepted; internal error recorded"}
    end
  end

  def check_bachs_signature(headers, body)
    timestamp = headers["x-bachs-timestamp"]
    signature = headers["x-bachs-signature"]
    return false unless timestamp && signature && bachs_webhook_timestamp_valid?(timestamp)

    expected = OpenSSL::HMAC.hexdigest("sha256", Config.bachs_webhook_secret, "#{timestamp}.#{body}")
    signature.bytesize == expected.bytesize && Rack::Utils.secure_compare(signature, expected)
  end

  def bachs_webhook_timestamp_valid?(timestamp)
    (Time.now.to_i - Integer(timestamp, 10)).abs <= BACHS_WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS
  rescue ArgumentError
    false
  end
end
