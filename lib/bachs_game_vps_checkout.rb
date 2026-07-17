# frozen_string_literal: true

require "bigdecimal"
require "time"

class BachsGameVpsCheckout
  def self.reconcile!(checkout_id, project: nil)
    checkout_id = GameVpsCheckout.normalize_checkout_id(checkout_id)
    return {status: "empty", count: 0} unless checkout_id

    items = GameVpsCheckout.pending_items(checkout_id, project:)
    if items.empty?
      processed_items = GameVpsCheckout.items_for_checkout(checkout_id, project:)
      return {status: "empty", count: 0} if processed_items.empty?

      return {status: "already_processed", count: processed_items.length, states: processed_items.map(&:status).uniq}
    end

    checkout = BachsClient.get_checkout(checkout_id)
    project ||= Project[items.first.project_id]
    metadata = checkout["metadata"] || {}
    expected_amount = items.sum { |item| BigDecimal(item.amount_cents.to_s) / 100 }.round(2)
    paid = checkout["status"].to_s.upcase == "COMPLETED" && checkout["payment_status"].to_s.downcase == "succeeded" &&
      checkout["currency"].to_s.upcase == "USD" && BigDecimal(checkout.fetch("amount").to_s).round(2) == expected_amount &&
      metadata["kind"] == "game_vps_checkout" && metadata["project_id"] == project.ubid
    return {status: "not_paid", count: items.length} unless paid

    subscription_id = checkout.dig("charge", "subscription_id") || checkout["subscription_id"] || checkout.dig("recurring", "subscription_id")
    return {status: "subscription_pending", count: items.length} unless subscription_id

    subscription = BachsClient.get_subscription(subscription_id)
    paid_until = subscription_paid_until(subscription)
    return {status: "subscription_not_active", count: items.length} unless paid_until

    result = nil
    DB.transaction do
      locked_items = GameVpsCheckout.pending_dataset(checkout_id, project:).for_update.all
      if locked_items.empty?
        processed_items = GameVpsCheckout.items_for_checkout(checkout_id, project:)
        result = {status: "already_processed", count: processed_items.length, states: processed_items.map(&:status).uniq}
      else
        result = GameVpsCheckout.activate_items!(locked_items, subscription_id:, paid_until:)
      end
    end
    result
  end

  def self.reconcile_event!(event)
    event_type = event["type"] || event["event_type"]
    data = event["data"] || event["payload"] || {}
    metadata = data["metadata"].is_a?(Hash) ? data["metadata"] : {}

    if event_type == "collection.succeeded" && metadata["kind"] == "game_vps_checkout"
      checkout_id = data["checkout_id"] || data.dig("checkout", "checkout_id")
      return reconcile!(checkout_id) if checkout_id
    end

    return {status: "ignored"} unless ["customer.subscription.created", "customer.subscription.updated", "invoice.paid"].include?(event_type)

    subscription_id = subscription_id_from(data)
    return {status: "ignored"} unless subscription_id

    items = GameVps.where(polar_subscription_id: subscription_id).exclude(status: %w[deleting deleted]).all
    return {status: "subscription_not_found"} if items.empty?

    subscription = BachsClient.get_subscription(subscription_id)
    paid_until = subscription_paid_until(subscription)
    return {status: "subscription_not_active", count: items.length} unless paid_until

    GameVps.where(id: items.map(&:id))
      .where(Sequel.|({paid_until: nil}, Sequel[:paid_until] < paid_until))
      .update(paid_until:, updated_at: Time.now)
    {status: "renewed", count: items.length}
  end

  def self.subscription_id_from(data)
    subscription = data["subscription"]
    [
      data["subscription_id"],
      subscription.is_a?(String) ? subscription : nil,
      subscription.is_a?(Hash) ? subscription["id"] : nil,
      subscription.is_a?(Hash) ? subscription["subscription_id"] : nil
    ].compact.map(&:to_s).find { !it.empty? }
  end

  def self.subscription_paid_until(subscription)
    return unless %w[active trialing].include?(subscription["status"].to_s.downcase)

    Time.iso8601(subscription.fetch("current_period_end"))
  rescue KeyError, ArgumentError
    nil
  end
end
