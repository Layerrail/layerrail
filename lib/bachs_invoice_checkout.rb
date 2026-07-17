# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "bachs_client"

class BachsInvoiceCheckout
  def self.create!(invoice:, project:, account:, success_url:, cancel_url:)
    existing = invoice.content["bachs_checkout"] || {}
    return existing if checkout_open?(existing)

    create_checkout!(invoice:, project:, account:, success_url:, cancel_url:, existing:)
  end

  def self.create_checkout!(invoice:, project:, account:, success_url:, cancel_url:, existing:)
    amount = BigDecimal(invoice.cost.to_s).round(2)
    amount_cents = (amount * 100).to_i
    raise ArgumentError, "Invoice amount is invalid" unless amount_cents.positive?

    attempt = existing["attempt"].to_i + 1

    metadata = {
      "kind" => "invoice_payment",
      "invoice" => invoice.ubid,
      "invoice_number" => invoice.invoice_number,
      "project" => project.ubid
    }
    product = BachsClient.create_product({
      name: "LayerRail invoice #{invoice.invoice_number}",
      description: "Exact payment for LayerRail invoice #{invoice.invoice_number}",
      price: {price_type: "fixed", currency: "USD", amount: format("%.2f", amount)},
      metadata:
    }, idempotency_key: "layerrail-invoice-product-#{invoice.ubid}")
    product_id = product.fetch("id")
    checkout = BachsClient.create_checkout({
      product_cart: [{product_id:, quantity: 1}],
      customer: {email: account.email, name: account.name},
      billing_currency: "USD",
      success_url:,
      cancel_url:,
      metadata:,
      reference: "layerrail-invoice-#{invoice.ubid}-#{attempt}",
      expires_in_minutes: 60
    }, idempotency_key: "layerrail-invoice-checkout-#{invoice.ubid}-#{attempt}")
    state = {
      "checkout_id" => checkout.fetch("checkout_id"),
      "checkout_url" => checkout.fetch("checkout_url"),
      "product_id" => product_id,
      "expires_at" => checkout.fetch("expires_at"),
      "attempt" => attempt,
      "status" => "open"
    }
    invoice.content["payment_gateway"] = "bachs"
    invoice.content["bachs_checkout"] = state
    invoice.save(columns: [:content])
    state
  end

  def self.reconcile!(invoice:, checkout_id:)
    checkout = BachsClient.get_checkout(checkout_id)
    metadata = checkout["metadata"] || {}
    expected_amount = BigDecimal(invoice.cost.to_s).round(2)
    paid_amount = BigDecimal((checkout["amount"] || "0").to_s).round(2)
    paid = checkout["status"].to_s.upcase == "COMPLETED" && checkout["payment_status"].to_s.downcase == "succeeded" && metadata["kind"] == "invoice_payment" &&
      metadata["invoice"] == invoice.ubid && metadata["project"] == invoice.project.ubid &&
      checkout["currency"].to_s.upcase == "USD" && paid_amount == expected_amount
    return {status: "not_paid", checkout:} unless paid

    changed = false
    DB.transaction do
      invoice.reload
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

  def self.reconcile_event!(event)
    payload = event["data"] || event["payload"] || {}
    metadata = payload["metadata"] || {}
    invoice_ubid = metadata["invoice"]
    checkout_id = payload["checkout_id"] || payload["checkout_session_id"] || payload.dig("checkout", "checkout_id") || payload.dig("checkout", "id")
    return {status: "ignored"} unless metadata["kind"] == "invoice_payment" && invoice_ubid && checkout_id

    invoice = Invoice.where(ubid: invoice_ubid).first
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
