# frozen_string_literal: true

require "bigdecimal"
require_relative "bachs_client"

class BachsInvoiceCheckout
  def self.create!(invoice:, project:, account:, success_url:, cancel_url:)
    existing = invoice.content["bachs_checkout"] || {}
    return existing if existing["checkout_url"] && existing["status"] == "open"

    amount_cents = (BigDecimal(invoice.cost.to_s) * 100).to_i
    raise ArgumentError, "Invoice amount is invalid" unless amount_cents.positive?

    metadata = {
      "kind" => "invoice_payment",
      "invoice" => invoice.ubid,
      "invoice_number" => invoice.invoice_number,
      "project" => project.ubid
    }
    product = BachsClient.create_product({
      name: "LayerRail invoice #{invoice.invoice_number}",
      description: "Exact payment for LayerRail invoice #{invoice.invoice_number}",
      price: {price_type: "fixed", currency: "USD", amount: format("%.2f", amount_cents / 100.0)},
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
      reference: "layerrail-invoice-#{invoice.ubid}",
      expires_in_minutes: 60
    }, idempotency_key: "layerrail-invoice-checkout-#{invoice.ubid}")
    state = {
      "checkout_id" => checkout.fetch("checkout_id"),
      "checkout_url" => checkout.fetch("checkout_url"),
      "product_id" => product_id,
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
    paid = checkout["status"] == "COMPLETED" && metadata["kind"] == "invoice_payment" &&
      metadata["invoice"] == invoice.ubid && metadata["project"] == invoice.project.ubid &&
      checkout["currency"].to_s.upcase == "USD" && paid_amount == expected_amount
    return {status: "not_paid", checkout:} unless paid

    changed = false
    DB.transaction do
      invoice.reload
      if invoice.status == "unpaid"
        invoice.content["payment_gateway"] = "bachs"
        invoice.content["bachs_checkout"] ||= {}
        invoice.content["bachs_checkout"].merge!("checkout_id" => checkout_id, "status" => "paid")
        invoice.update(status: "paid", content: invoice.content)
        changed = true
      end
    end
    invoice.send_success_email if changed
    BachsClient.archive_product(invoice.content.dig("bachs_checkout", "product_id")) if changed && invoice.content.dig("bachs_checkout", "product_id")
    {status: changed ? "paid" : "already_paid", checkout:}
  end

  def self.reconcile_event!(event)
    payload = event["data"] || event["payload"] || {}
    metadata = payload["metadata"] || {}
    invoice_ubid = metadata["invoice"]
    checkout_id = payload["checkout_id"] || payload["checkout_session_id"] || payload.dig("checkout", "checkout_id") || payload.dig("checkout", "id")
    return {status: "ignored"} unless invoice_ubid && checkout_id

    invoice = Invoice.where(ubid: invoice_ubid).first
    return {status: "invoice_not_found"} unless invoice

    reconcile!(invoice:, checkout_id:)
  end
end
