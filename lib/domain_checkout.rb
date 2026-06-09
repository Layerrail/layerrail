# frozen_string_literal: true

class DomainCheckout
  def self.cart_items(project)
    [
      *project.domain_registrations_dataset.where(status: "cart").all,
      *project.domain_orders_dataset.where(status: "cart").all
    ]
  end

  def self.pending_items(checkout_id, project: nil)
    registrations = DomainRegistration.where(status: "pending_payment", checkout_id:)
    orders = DomainOrder.where(status: "pending_payment", checkout_id:)
    if project
      registrations = registrations.where(project_id: project.id)
      orders = orders.where(project_id: project.id)
    end
    [registrations.all, orders.all]
  end

  def self.amount_cents(items)
    items.sum { it.amount_cents.to_i }
  end

  def self.mark_pending!(items, checkout_id)
    DB.transaction do
      items.each do |item|
        item.update(status: "pending_payment", checkout_id:, updated_at: Time.now)
      end
    end
  end

  def self.reconcile!(checkout_id, project: nil, checkout_session: nil)
    registrations, orders = pending_items(checkout_id, project:)
    items = registrations + orders
    return {status: "empty", count: 0} if items.empty?

    checkout_session ||= PolarClient.get_checkout(checkout_id)
    project ||= Project[items.first.project_id]
    metadata = checkout_session["metadata"] || {}
    expected_amount_cents = amount_cents(items)
    checkout_amount = Integer(checkout_session["amount"] || checkout_session["total_amount"] || 0)

    unless checkout_session["status"] == "succeeded" &&
        checkout_session["external_customer_id"] == project.ubid &&
        metadata["kind"] == "domain_checkout" &&
        metadata["project_id"] == project.ubid &&
        checkout_amount == expected_amount_cents
      return {status: "not_paid", count: items.length}
    end

    DB.transaction do
      registrations.each do |domain_registration|
        domain_registration.update(status: "registering", failure_message: nil, updated_at: Time.now)
        Prog::Domain::DomainRegistrationNexus.assemble(domain_registration)
      end
      orders.each do |domain_order|
        domain_order.update(status: "processing", failure_message: nil, updated_at: Time.now)
        Prog::Domain::DomainOrderNexus.assemble(domain_order)
      end
    end

    {status: "processing", count: items.length}
  end
end
