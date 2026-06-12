# frozen_string_literal: true

class GameVpsCheckout
  def self.pending_items(checkout_id, project: nil)
    dataset = GameVps.where(status: "pending_payment", checkout_id:)
    dataset = dataset.where(project_id: project.id) if project
    dataset.all
  end

  def self.amount_cents(items)
    items.sum(&:amount_cents)
  end

  def self.mark_pending!(game_vps, checkout_id)
    GameVps.where(id: game_vps.id).update(
      checkout_id:,
      subscription_amount_cents: game_vps.amount_cents,
      status: "pending_payment",
      updated_at: Time.now
    )
    game_vps.refresh
  end

  def self.reconcile!(checkout_id, project: nil, checkout_session: nil)
    items = pending_items(checkout_id, project:)
    return {status: "empty", count: 0} if items.empty?

    checkout_session ||= PolarClient.get_checkout(checkout_id)
    project ||= Project[items.first.project_id]
    metadata = checkout_session["metadata"] || {}
    expected_amount_cents = amount_cents(items)
    checkout_amount = Integer(checkout_session["amount"] || checkout_session["total_amount"] || 0)

    unless checkout_session["status"] == "succeeded" &&
        checkout_session["external_customer_id"] == project.ubid &&
        metadata["kind"] == "game_vps_checkout" &&
        metadata["project_id"] == project.ubid &&
        checkout_amount == expected_amount_cents
      return {status: "not_paid", count: items.length}
    end

    DB.transaction do
      items.each do |game_vps|
        GameVps.where(id: game_vps.id).update(status: "creating", failure_message: nil, paid_until: Time.now + (30 * 24 * 60 * 60), updated_at: Time.now)
        game_vps.refresh
        Prog::GameVpsNexus.assemble(game_vps)
      end
    end

    {status: "provisioning", count: items.length}
  end
end
