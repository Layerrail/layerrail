# frozen_string_literal: true

require "time"

class InferenceUsageCollection
  Customer = Data.define(:email, :name)

  # Bachs currently documents hosted amount-based checkout, not arbitrary
  # off-session collection. Never interpret a verification payment ID as a card.
  def self.collect!(invoice, now: Time.now)
    ready = DB.transaction do
      invoice = Invoice.where(id: invoice.id).for_update.first
      next false unless invoice.status == "unpaid"

      state = invoice.content["usage_collection"] || {}
      next false if state["next_attempt_at"] && Time.parse(state["next_attempt_at"]) > now

      state["next_attempt_at"] = (now + 5 * 60).utc.iso8601
      invoice.update(content: invoice.content.merge("usage_collection" => state))
      true
    end
    return unless ready

    if InferenceUsageBilling.decimal(invoice.cost).zero?
      invoice.update(status: "paid")
      invoice.send_success_email
      return
    end
    raise "Bachs must be configured to collect inference usage" unless BachsClient.invoice_checkout_enabled?

    existing = invoice.content["bachs_checkout"]
    if existing && existing["checkout_id"]
      result = BachsInvoiceCheckout.reconcile!(invoice:, checkout_id: existing["checkout_id"])
      return if %w[paid already_paid].include?(result[:status])
    end

    data = invoice.content["billing_info"] || {}
    raise "Usage invoice requires a billing email" if data["email"].to_s.empty?

    project = invoice.project
    invoice_url = "#{Config.base_url}#{project.path}/billing#{invoice.path}"
    BachsInvoiceCheckout.create!(invoice:, project:,
      account: Customer.new(email: data["email"], name: data["name"] || data["email"]),
      success_url: "#{invoice_url}/success", cancel_url: "#{Config.base_url}#{project.path}/billing")

    # The collection lease prevents concurrent deliveries. Mark completion only
    # after sending; PDF/SMTP failures must leave the notification retryable.
    invoice.refresh
    unless invoice.content.fetch("usage_collection")["notified_at"] || invoice.status != "unpaid"
      invoice.send_payment_due_email
      DB.transaction do
        invoice.lock!
        state = invoice.content.fetch("usage_collection")
        invoice.update(content: invoice.content.merge("usage_collection" => state.merge("notified_at" => now.utc.iso8601)))
      end
    end
  end
end
