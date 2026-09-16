# frozen_string_literal: true

require "bigdecimal"

# New inference records are immutable in price and cumulative in quantity. Both
# writers and this allocator lock the project before updating their counters.
class InferenceUsageBilling
  def self.records(project)
    BillingRecord.where(project_id: project.id)
      .with_tag("paid_inference", true)
      .where { amount > inference_invoiced_amount }
      .order(:id).all
  end

  def self.decimal(value)
    BigDecimal(value.to_s)
  end

  def self.record_cost(record)
    price = decimal(record.resource_tags["unit_price"] || record.billing_rate.fetch("unit_price"))
    raise "Paid inference record has no positive price: #{record.id}" unless price.positive?

    (record.amount - record.inference_invoiced_amount) * price
  end

  def self.unbilled_cost(project)
    records(project).sum { record_cost(it) } + project.inference_billing_remainder
  end

  def self.period_cost(project, begin_time, end_time = Time.now)
    BillingRecord.where(project_id: project.id).with_tag("paid_inference", true)
      .overlapping(begin_time, end_time).all.sum do |record|
        record.amount * decimal(record.resource_tags["unit_price"] || record.billing_rate.fetch("unit_price"))
      end
  end

  def self.threshold
    [Config.inference_usage_charge_threshold_cents, 100].max / BigDecimal("100")
  end

  def self.payment_required?(project)
    project.has_outstanding_invoice? || unbilled_cost(project) - project.credit >= threshold
  end

  # No collection calls here. Counter allocation, credit consumption, and the
  # invoice commit together; collection may safely be retried after a crash.
  def self.settle!(project:, eur_rate:, now: Time.now)
    billing_info = project.billing_info
    billing_info&.billing_data # Fetch the address before locking usage writers.
    DB.transaction do
      project = Project.where(id: project.id).for_update.first
      raise "Billing profile changed during settlement; retry" unless project.billing_info_id == billing_info&.id

      project.associations[:billing_info] = billing_info
      next if project.invoices_dataset.where(billing_kind: "inference_usage", status: "unpaid").any?

      pending = records(project)
      next if pending.empty?

      subtotal = pending.sum { record_cost(it) } + project.inference_billing_remainder
      month_start = Time.utc(now.utc.year, now.utc.month, 1)
      month_end_due = pending.any? { it.span.begin < month_start }
      minimum = [Config.inference_usage_minimum_charge_cents, 100].max / BigDecimal("100")
      ready = subtotal >= threshold || (month_end_due && subtotal >= minimum)
      next unless ready

      credit = [subtotal, project.credit].min
      net = subtotal - credit
      # Do not forgive tiny balances or ask Bachs to collect below its USD $1
      # minimum. They remain unallocated and join the next usage invoice.
      next if net.positive? && net < minimum
      # During the month, credits must be exhausted before the unpaid balance
      # reaches the payment threshold used by the inference access gate.
      next if !month_end_due && net.positive? && net < threshold

      rounded_net = net.floor(2)
      carry = net - rounded_net
      begin_time = pending.map { it.span.begin }.min
      items = pending.map do |record|
        rate = record.billing_rate
        {
          project:,
          resource_id: record.resource_id,
          resource_name: record.resource_name,
          resource_type: "InferenceTokens",
          resource_family: rate.fetch("resource_family"),
          location: rate.fetch("location"),
          amount: record.amount - record.inference_invoiced_amount,
          duration: 1,
          cost: record_cost(record),
          begin_time: record.span.begin,
          unit_price: record.resource_tags["unit_price"] || rate.fetch("unit_price"),
          resource_tags: record.resource_tags,
        }
      end
      content = InvoiceGenerator.new(begin_time, now, eur_rate:, usage_records: items).run.fetch(0).content
      content["subtotal"] = subtotal.to_f
      content["credit"] = credit.to_f
      content["discount"] = 0
      content["cost"] = rounded_net.to_f
      content["rounding_carry"] = carry.to_s("F")
      content["previous_rounding_carry"] = project.inference_billing_remainder.to_s("F")
      content["usage_allocations"] = pending.map do |record|
        {
          "billing_record_id" => record.id,
          "from_amount" => record.inference_invoiced_amount.to_s("F"),
          "to_amount" => record.amount.to_s("F"),
          "cost" => record_cost(record).to_s("F"),
        }
      end
      if (vat = content["vat_info"]) && !vat["reversed"]
        raise "EUR rate required for VAT invoice" unless eur_rate && decimal(eur_rate).positive?

        vat["amount"] = (rounded_net * decimal(vat.fetch("rate")) / 100).round(2).to_f
        content["cost"] = (rounded_net + decimal(vat["amount"])).to_f
      end
      number = "AI-#{now.utc.strftime("%y%m")}-#{project.id[-10..]}-#{format("%04d", project.invoices_dataset.count + 1)}"
      invoice = Invoice.create(project_id: project.id, billing_kind: "inference_usage", invoice_number: number,
        content:, begin_time:, end_time: now)
      pending.each { it.update(inference_invoiced_amount: it.amount) }
      project.update(credit: project.credit - credit, inference_billing_remainder: carry)
      invoice
    end
  end
end
