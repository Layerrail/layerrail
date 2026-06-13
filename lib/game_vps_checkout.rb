# frozen_string_literal: true

class GameVpsCheckout
  def self.pending_dataset(checkout_id, project: nil)
    dataset = GameVps.where(status: "pending_payment", checkout_id: normalize_checkout_id(checkout_id))
    dataset = dataset.where(project_id: project.id) if project
    dataset
  end

  def self.pending_items(checkout_id, project: nil)
    pending_dataset(checkout_id, project:).all
  end

  def self.items_for_checkout(checkout_id, project: nil)
    dataset = GameVps.where(checkout_id: normalize_checkout_id(checkout_id))
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
      failure_message: nil,
      updated_at: Time.now
    )
    game_vps.refresh
  end

  def self.reconcile!(checkout_id, project: nil, checkout_session: nil)
    checkout_id = normalize_checkout_id(checkout_id)
    return {status: "empty", count: 0} unless checkout_id

    items = pending_items(checkout_id, project:)
    if items.empty?
      processed_items = items_for_checkout(checkout_id, project:)
      return {status: "empty", count: 0} if processed_items.empty?

      return {
        status: "already_processed",
        count: processed_items.length,
        states: processed_items.map(&:status).uniq
      }
    end

    checkout_session ||= PolarClient.get_checkout(checkout_id)
    project ||= Project[items.first.project_id]
    metadata = checkout_session["metadata"] || {}
    expected_amount_cents = amount_cents(items)
    checkout_amount = checkout_amount_cents(checkout_session)
    checkout_status = checkout_session["status"].to_s
    external_customer_id = checkout_session["external_customer_id"].to_s
    polar_subscription_id = checkout_subscription_id(checkout_session)
    metadata_kind = metadata["kind"].to_s
    metadata_project_id = metadata["project_id"].to_s

    unless checkout_paid?(checkout_status) &&
        external_customer_id == project.ubid &&
        metadata_kind == "game_vps_checkout" &&
        metadata_project_id == project.ubid &&
        (!checkout_amount.positive? || checkout_amount == expected_amount_cents)
      return {status: "not_paid", count: items.length}
    end

    result = nil
    DB.transaction do
      locked_items = pending_dataset(checkout_id, project:).for_update.all
      if locked_items.empty?
        processed_items = items_for_checkout(checkout_id, project:)
        result = {
          status: "already_processed",
          count: processed_items.length,
          states: processed_items.map(&:status).uniq
        }
      else
        locked_items.each do |game_vps|
          GameVps.where(id: game_vps.id).update(
            status: "creating",
            failure_message: nil,
            polar_subscription_id:,
            paid_until: Time.now + (30 * 24 * 60 * 60),
            updated_at: Time.now
          )
          game_vps.refresh
          begin
            Prog::GameVpsNexus.assemble(game_vps) unless game_vps.strand
          rescue Sequel::UniqueConstraintViolation
            nil
          end
        end
      end
    end

    return result if result

    {status: "provisioning", count: items.length}
  end

  def self.checkout_paid?(status)
    %w[succeeded paid complete completed confirmed].include?(status)
  end

  def self.checkout_subscription_id(checkout_session)
    [
      checkout_session["subscription_id"],
      checkout_session.dig("subscription", "id"),
      checkout_session.dig("order", "subscription_id"),
      checkout_session.dig("order", "subscription", "id")
    ].each do |candidate|
      candidate = candidate.to_s.strip
      return candidate unless candidate.empty?
    end

    nil
  end

  def self.checkout_amount_cents(checkout_session)
    [
      checkout_session["amount_cents"],
      checkout_session["total_amount_cents"],
      checkout_session["amount"],
      checkout_session["total_amount"],
      checkout_session["amount"].is_a?(Hash) ? checkout_session["amount"]["amount"] : nil,
      checkout_session["total"].is_a?(Hash) ? checkout_session["total"]["amount"] : nil,
      checkout_session["price"].is_a?(Hash) ? checkout_session["price"]["price_amount"] : nil
    ].each do |candidate|
      next if candidate.nil? || candidate.is_a?(Hash) || candidate.is_a?(Array)

      return Integer(candidate)
    rescue ArgumentError, TypeError
      next
    end

    0
  end

  def self.normalize_checkout_id(checkout_id)
    checkout_id = checkout_id.to_s.strip
    checkout_id.empty? ? nil : checkout_id
  end
end
