# frozen_string_literal: true

class Serializers::DomainOrder < Serializers::Base
  def self.serialize_internal(order, _options = {})
    {
      id: order.ubid,
      domain: order.domain,
      kind: order.kind,
      state: order.display_state,
      years: order.years,
      currency: order.currency,
      amount_cents: order.amount_cents,
      checkout_id: order.checkout_id,
      due_at: order.due_at,
      completed_at: order.completed_at,
      failure_message: order.failure_message,
      created_at: order.created_at,
      updated_at: order.updated_at
    }
  end
end
