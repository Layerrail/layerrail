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

    notify_purchase_success_safely!(project, items)
    {status: "processing", count: items.length}
  end

  def self.notify_pending_safely!(items, project, checkout_url)
    notify_pending!(items, project, checkout_url)
  rescue => ex
    Clog.emit("domain checkout pending email failed", Util.exception_to_hash(ex, into: {domain_checkout_pending_email_failed: {project_ubid: project.ubid}}))
  end

  def self.notify_purchase_success_safely!(project, items)
    notify_purchase_success!(project, items)
  rescue => ex
    Clog.emit("domain checkout success email failed", Util.exception_to_hash(ex, into: {domain_checkout_success_email_failed: {project_ubid: project.ubid}}))
  end

  def self.notify_pending!(items, project, checkout_url)
    receivers = project.accounts_dataset.select_map(:email).compact.uniq
    return if receivers.empty?

    Util.send_email(
      receivers,
      "Complete your LayerRail domain checkout",
      greeting: "Hi,",
      body: [
        "Your domain cart is ready for payment.",
        "Total: #{amount_label(items)}",
        "Items: #{item_summary(items)}",
        "Open the checkout to finish the purchase and start provisioning."
      ],
      button_title: "Complete checkout",
      button_link: checkout_url,
      author_name: "LayerRail"
    )
  end

  def self.notify_purchase_success!(project, items)
    receivers = project.accounts_dataset.select_map(:email).compact.uniq
    return if receivers.empty?

    Util.send_email(
      receivers,
      "LayerRail domain purchase received",
      greeting: "Hi,",
      body: [
        "Payment was successful and LayerRail has started provisioning your domain request.",
        "Total: #{amount_label(items)}",
        "Items: #{item_summary(items)}",
        "We'll keep the project updated as registration, transfer, or renewal work completes."
      ],
      button_title: "Open domains",
      button_link: "#{Config.base_url}#{project.path}/domain",
      author_name: "LayerRail"
    )
  end

  def self.amount_label(items)
    "$#{format("%0.2f", amount_cents(items) / 100.0)}"
  end

  def self.item_summary(items)
    items.map { "#{it.domain} (#{it.is_a?(DomainRegistration) ? "registration" : it.display_kind})" }.join(", ")
  end
end
