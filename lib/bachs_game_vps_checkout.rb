# frozen_string_literal: true

require "bigdecimal"
require "time"

class BachsGameVpsCheckout
  def self.reconcile!(checkout_id, project: nil)
    checkout = BachsClient.get_checkout(checkout_id)
    items = GameVpsCheckout.pending_items(checkout_id, project:)
    return {status: "empty", count: 0} if items.empty?

    project ||= Project[items.first.project_id]
    metadata = checkout["metadata"] || {}
    expected_amount = items.sum { |item| BigDecimal(item.amount_cents.to_s) / 100 }.round(2)
    paid = checkout["status"] == "COMPLETED" && checkout["payment_status"] == "succeeded" &&
      checkout["currency"].to_s.upcase == "USD" && BigDecimal(checkout.fetch("amount").to_s).round(2) == expected_amount &&
      metadata["kind"] == "game_vps_checkout" && metadata["project_id"] == project.ubid
    return {status: "not_paid", count: items.length} unless paid

    subscription_id = checkout.dig("charge", "subscription_id")
    GameVpsCheckout.activate_items!(items, subscription_id:)
  end

  def self.reconcile_event!(event)
    data = event["data"] || event["payload"] || {}
    checkout_id = data["checkout_id"] || data.dig("checkout", "checkout_id")
    return reconcile!(checkout_id) if checkout_id

    subscription_id = data["subscription_id"]
    return {status: "ignored"} unless subscription_id && data["status"] == "succeeded"

    items = GameVps.where(polar_subscription_id: subscription_id).exclude(status: %w[deleting deleted]).all
    return {status: "subscription_not_found"} if items.empty?

    subscription = BachsClient.get_subscription(subscription_id)
    GameVps.where(id: items.map(&:id)).update(paid_until: Time.parse(subscription.fetch("current_period_end")), updated_at: Time.now)
    {status: "renewed", count: items.length}
  end
end
