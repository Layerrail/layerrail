# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "time"
require_relative "bachs_client"

class BachsInvoiceCheckout
  IDEMPOTENCY_RETENTION_SECONDS = 24 * 60 * 60

  def self.create!(invoice:, project:, account:, success_url:, cancel_url:)
    invoice.refresh
    existing = invoice.content["bachs_checkout"] || {}
    if existing["checkout_id"] && !checkout_open?(existing)
      result = reconcile!(invoice:, checkout_id: existing["checkout_id"])
      raise BachsAPIError.new(409, "Invoice has already been paid") if %w[paid already_paid].include?(result[:status])

      # Local expiry alone does not prove the preceding payment failed. A
      # payment may await confirmation/action, or its webhook may be delayed.
      checkout = result.fetch(:checkout)
      unless %w[expired cancelled canceled].include?(checkout["status"].to_s.downcase) &&
          ["", "failed", "canceled", "cancelled", "requires_payment_method"].include?(checkout["payment_status"].to_s.downcase)
        return existing
      end
    end

    # Call outside a surrounding transaction so this request commits before
    # contacting Bachs. A lost response must retry the same body and key.
    DB.transaction do
      invoice.lock!
      raise ArgumentError, "Invoice belongs to another project" unless invoice.project_id == project.id
      raise BachsAPIError.new(409, "Invoice is not payable") unless invoice.payable?

      existing = invoice.content["bachs_checkout"] || {}
      return existing if checkout_open?(existing)
      raise BachsAPIError.new(409, "Invoice checkout needs payment review before another attempt") if existing["status"] == "review_required"

      unless existing["status"] == "creating"
        state = checkout_request(invoice:, project:, account:, success_url:, cancel_url:, existing:)
        invoice.update(content: invoice.content.merge("payment_gateway" => "bachs", "bachs_checkout" => state))
      end
    end

    result = DB.transaction do
      invoice.lock!
      raise BachsAPIError.new(409, "Invoice is not payable") unless invoice.payable?

      existing = invoice.content.fetch("bachs_checkout")
      return existing if checkout_open?(existing)

      if (reason = request_review_reason(existing))
        state = existing.merge("status" => "review_required", "reason" => reason)
        invoice.update(content: invoice.content.merge("bachs_checkout" => state))
        next state
      end

      checkout = BachsClient.create_checkout(
        JSON.parse(existing.fetch("request_body"), symbolize_names: true),
        idempotency_key: existing.fetch("idempotency_key"),
      )
      state = {
        "checkout_id" => checkout.fetch("checkout_id"),
        "checkout_url" => checkout.fetch("checkout_url"),
        "expires_at" => checkout.fetch("expires_at"),
        "attempt" => existing.fetch("attempt"),
        "status" => "open",
      }
      invoice.update(content: invoice.content.merge("payment_gateway" => "bachs", "bachs_checkout" => state))
      state
    end
    raise BachsAPIError.new(409, "Invoice checkout needs payment review before another attempt") if result["status"] == "review_required"

    result
  end

  def self.checkout_request(invoice:, project:, account:, success_url:, cancel_url:, existing:)
    amount = BigDecimal(invoice.cost.to_s).round(2)
    raise ArgumentError, "Bachs invoice checkout requires at least USD 1.00" unless amount.finite? && amount >= 1

    attempt = existing["attempt"].to_i + 1
    customer_id = project.billing_info&.bachs_customer_id
    payload = {
      pricing: {price_type: "fixed", currency: "USD", amount: format("%.2f", amount)},
      customer: customer_id ? {customer_id:} : {email: account.email, name: account.name || account.email},
      billing_currency: "USD",
      success_url:,
      cancel_url:,
      metadata: {
        kind: "invoice_payment",
        invoice: invoice.ubid,
        invoice_number: invoice.invoice_number,
        project: project.ubid,
      },
      reference: "layerrail-invoice-#{invoice.ubid}-#{attempt}",
      expires_in_minutes: 60,
    }
    {
      "attempt" => attempt,
      "status" => "creating",
      "requested_at" => Time.now.utc.iso8601,
      "idempotency_scope" => idempotency_scope,
      "idempotency_key" => "layerrail-invoice-checkout-v2-#{invoice.ubid}-#{attempt}",
      "request_body" => JSON.generate(payload),
    }
  end

  def self.idempotency_scope
    Digest::SHA256.hexdigest([Config.bachs_api_base_url, Config.bachs_api_key].join("\0"))
  end

  def self.request_review_reason(state)
    return "idempotency_scope_changed" unless state["idempotency_scope"] == idempotency_scope
    return "idempotency_window_expired" unless state["status"] == "creating" && Time.iso8601(state.fetch("requested_at")) + IDEMPOTENCY_RETENTION_SECONDS > Time.now

    nil
  rescue ArgumentError, KeyError
    "idempotency_window_expired"
  end

  def self.reconcile!(invoice:, checkout_id:)
    checkout = BachsClient.get_checkout(checkout_id)
    changed = false
    DB.transaction do
      invoice.lock!
      return {status: "not_paid", checkout:} unless matching_payment?(invoice, checkout)
      return {status: "not_paid", checkout:} unless %w[unpaid paid].include?(invoice.status)

      if invoice.status == "unpaid"
        content = invoice.content.merge("payment_gateway" => "bachs")
        content["bachs_checkout"] = (content["bachs_checkout"] || {}).merge("checkout_id" => checkout_id, "status" => "paid")
        invoice.update(status: "paid", content:)
        changed = true
      end
    end
    complete_payment_side_effects(invoice) if changed
    {status: changed ? "paid" : "already_paid", checkout:}
  end

  def self.matching_payment?(invoice, checkout)
    metadata = checkout["metadata"] || {}
    expected_amount = BigDecimal(invoice.cost.to_s).round(2)
    paid_amount = BigDecimal((checkout["amount"] || "0").to_s)
    checkout["status"].to_s.downcase == "completed" && checkout["payment_status"].to_s.downcase == "succeeded" &&
      metadata["kind"] == "invoice_payment" && metadata["invoice"] == invoice.ubid && metadata["project"] == invoice.project.ubid &&
      checkout["currency"].to_s.upcase == "USD" && paid_amount.finite? && paid_amount == expected_amount
  rescue ArgumentError
    false
  end

  def self.reconcile_event!(event)
    payload = event["data"] || event["payload"] || {}
    metadata = payload["metadata"] || {}
    invoice_ubid = metadata["invoice"]
    checkout_id = payload["checkout_id"] || payload["checkout_session_id"] || payload.dig("checkout", "checkout_id") || payload.dig("checkout", "id")
    return {status: "ignored"} unless metadata["kind"] == "invoice_payment" && invoice_ubid && checkout_id

    invoice_id = UBID.to_uuid(invoice_ubid.to_s)
    invoice = Invoice[invoice_id] if invoice_id
    return {status: "invoice_not_found"} unless invoice

    reconcile!(invoice:, checkout_id:)
  end

  def self.checkout_open?(state)
    state["checkout_url"] && state["status"] == "open" && Time.iso8601(state["expires_at"].to_s) > Time.now
  rescue ArgumentError
    false
  end

  def self.complete_payment_side_effects(invoice)
    invoice.send_success_email
  rescue => ex
    Clog.emit("Bachs invoice payment receipt failed", Util.exception_to_hash(ex, into: {bachs_invoice_receipt_failed: {invoice_ubid: invoice.ubid}}))
  ensure
    archive_product(invoice)
  end

  def self.archive_product(invoice)
    product_id = invoice.content.dig("bachs_checkout", "product_id")
    BachsClient.archive_product(product_id) if product_id
  rescue BachsAPIError => ex
    Clog.emit("Bachs invoice product archive failed", Util.exception_to_hash(ex, into: {bachs_invoice_product_archive_failed: {invoice_ubid: invoice.ubid}}))
  end
end
