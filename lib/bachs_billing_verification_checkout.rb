# frozen_string_literal: true

require "bigdecimal"

class BachsBillingVerificationCheckout
  class VerificationError < StandardError; end

  def self.create!(project:, account:, success_url:, cancel_url:)
    product_id = Config.bachs_verification_product_id.to_s
    raise "Set BACHS_VERIFICATION_PRODUCT_ID to enable Bachs billing verification." if product_id.empty?

    attempt = Time.now.utc.strftime("%Y%m%d%H%M")
    idempotency_key = "layerrail-billing-verification-#{project.ubid}-#{attempt}"
    BachsClient.create_checkout(
      {
        product_cart: [{product_id:, quantity: 1}],
        customer: {name: account.name || account.email, email: account.email},
        billing_currency: "USD",
        payment_method_types: ["USD_CARD"],
        success_url:,
        cancel_url:,
        metadata: {
          kind: "project_billing_setup",
          project_id: project.ubid,
          account_id: account.ubid,
          product_id:,
          amount_cents: Config.bachs_verification_amount_cents,
        },
        reference: idempotency_key,
        expires_in_minutes: 60,
      },
      idempotency_key:,
    )
  end

  def self.reconcile!(checkout_id, project:)
    checkout = BachsClient.get_checkout(checkout_id)
    metadata = checkout["metadata"].is_a?(Hash) ? checkout["metadata"] : {}
    product_id = Config.bachs_verification_product_id.to_s
    expected_amount = BigDecimal(Config.bachs_verification_amount_cents.to_s) / 100
    products = Array(checkout["products"])
    paid = checkout["status"].to_s.upcase == "COMPLETED" &&
      checkout["payment_status"].to_s.downcase == "succeeded" &&
      checkout["currency"].to_s.upcase == "USD" &&
      BigDecimal(checkout.fetch("amount", "0").to_s).round(2) == expected_amount.round(2) &&
      metadata["kind"] == "project_billing_setup" &&
      metadata["project_id"] == project.ubid &&
      metadata["product_id"] == product_id &&
      products.any? { it["product_id"] == product_id }
    return {status: "not_paid", checkout:} unless paid

    payment_id = checkout.dig("charge", "payment_id") || checkout.dig("charge", "charge_id") || checkout_id
    customer_id = checkout.dig("customer", "customer_id") || checkout.dig("customer", "id")
    unless BillingInfo.valid_bachs_customer_id?(customer_id)
      raise VerificationError, "Bachs verification checkout did not include a valid customer id"
    end
    refund_status = refund_verification_charge(checkout_id, checkout)
    changed = false

    DB.transaction do
      locked_project = Project.where(id: project.id).for_update.first
      billing_info = locked_project.billing_info
      unless billing_info
        billing_info = BillingInfo.create(stripe_id: "bachs:#{project.ubid}", bachs_customer_id: customer_id)
        locked_project.update(billing_info_id: billing_info.id)
        changed = true
      end

      if billing_info[:bachs_customer_id] != customer_id
        billing_info.update(bachs_customer_id: customer_id)
        changed = true
      end

      payment_method_id = "bachs:payment:#{payment_id}"
      unless billing_info.payment_methods_dataset.first(stripe_id: payment_method_id)
        PaymentMethod.create(
          billing_info_id: billing_info.id,
          stripe_id: payment_method_id,
          card_fingerprint: "bachs:#{customer_id}",
        )
        changed = true
      end
    end

    {
      status: changed ? "verified" : "already_verified",
      refund_status:,
      checkout:,
    }
  end

  def self.reconcile_event!(event)
    return {status: "ignored"} unless event["type"] == "collection.succeeded"

    data = event["data"] || event["payload"] || {}
    metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}
    return {status: "ignored"} unless metadata["kind"] == "project_billing_setup"

    checkout_id = data["checkout_id"] || data.dig("checkout", "checkout_id")
    project_id = UBID.to_uuid(metadata["project_id"].to_s)
    return {status: "ignored"} unless checkout_id && project_id

    project = Project[project_id]
    return {status: "project_not_found"} unless project

    reconcile!(checkout_id, project:)
  end

  def self.refund_verification_charge(checkout_id, checkout)
    charge = checkout["charge"].is_a?(Hash) ? checkout["charge"] : {}
    charge_id = charge["charge_id"] || charge["payment_id"]
    raise VerificationError, "Bachs verification checkout did not include a refundable charge id" unless charge_id

    idempotency_key = "layerrail-billing-verification-refund-#{checkout_id}"
    refund = BachsClient.create_refund(
      {
        charge_id:,
        reference: idempotency_key,
        reason: "Automatic LayerRail billing verification refund",
        idempotency_key:,
      },
      idempotency_key:,
    )
    refund["status"] || "processing"
  end
end
