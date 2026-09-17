# frozen_string_literal: true

require "digest"
require "mail"

class InvoiceEmailDelivery
  LEASE_SECONDS = 5 * 60
  RETRY_WINDOW_SECONDS = 23 * 60 * 60
  IDEMPOTENCY_HEADER = "X-LayerRail-Idempotency-Key"

  def self.sent?(invoice:, notification_type:)
    DB[:invoice_email_delivery].where(invoice_id: invoice.id, notification_type:, status: "sent").any?
  end

  def self.deliver!(invoice:, notification_type:, receivers:, subject:, **options)
    return false if Array(receivers).compact.empty?

    # Never send mail for an uncommitted invoice or lose the reservation when
    # the caller's transaction rolls back. Recurring scans retry committed work.
    if DB.in_transaction?
      DB.after_commit { perform!(invoice:, notification_type:, receivers:, subject:, **options) }
      return :queued
    end

    perform!(invoice:, notification_type:, receivers:, subject:, **options)
  end

  def self.perform!(invoice:, notification_type:, receivers:, subject:, now: Time.now, **options)
    key = {invoice_id: invoice.id, notification_type:}
    dataset = DB[:invoice_email_delivery].where(key)
    reservation = DB.transaction do
      DB[:invoice_email_delivery].insert_conflict.insert(key)
      row = dataset.for_update.first
      next if row[:status] == "sent" || row[:status] == "needs_review"
      next if row[:next_attempt_at] && row[:next_attempt_at] > now

      scope = idempotency_scope
      if row[:first_attempt_at] && (row[:first_attempt_at] + RETRY_WINDOW_SECONDS <= now || row[:idempotency_scope] != scope || Config.mail_driver != :resend)
        dataset.update(status: "needs_review", last_error_class: "DeliveryConfirmationRequired")
        Clog.emit("Invoice email needs delivery review", {invoice_id: invoice.id, notification_type:})
        next
      end

      # Reuse identical content and attachment bytes after a timeout. Resend
      # rejects a repeated idempotency key if its request body has changed.
      message = row[:message] || EmailRenderer.mail("/", receivers, subject, **options).encoded
      dataset.update(status: "sending", message:, idempotency_scope: scope,
        first_attempt_at: row[:first_attempt_at] || now, last_attempt_at: now,
        next_attempt_at: now + LEASE_SECONDS, attempts: row[:attempts] + 1)
      {message:, generation: row[:generation], previous_attempt: !row[:first_attempt_at].nil?}
    end
    return false unless reservation

    mail = Mail.read_from_string(reservation.fetch(:message))
    mail[IDEMPOTENCY_HEADER] = "layerrail-invoice-#{invoice.id}-#{notification_type}-#{reservation.fetch(:generation)}"
    mail.deliver!
    dataset.update(status: "sent", sent_at: Time.now, next_attempt_at: nil,
      provider_message_id: mail["X-LayerRail-Delivery-Id"]&.value, last_error_class: nil, message: nil)
    true
  rescue => ex
    changes = {status: "pending", last_error_class: ex.class.name}
    # A definitive rejection is safe to retry even after the idempotency
    # window. A timeout or server error may have been accepted remotely.
    if reservation && !reservation[:previous_attempt] && ex.is_a?(ResendDeliveryError) && [400, 401, 403, 422, 429].include?(ex.status)
      changes.merge!(first_attempt_at: nil, message: nil, generation: Sequel[:generation] + 1)
    end
    dataset&.exclude(status: "sent")&.update(changes)
    raise
  end

  def self.idempotency_scope
    Digest::SHA256.hexdigest([Config.mail_driver, Config.resend_api_key].join("\0"))
  end
end
