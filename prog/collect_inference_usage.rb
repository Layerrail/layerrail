# frozen_string_literal: true

require "excon"

class Prog::CollectInferenceUsage < Prog::Base
  label def wait
    if frame["next_scan_at"]
      delay = Time.parse(frame["next_scan_at"]) - Time.now
      nap delay.ceil if delay.positive?
    end
    update_stack({"next_scan_at" => (Time.now + 30).utc.iso8601})
    project_ids = BillingRecord.with_tag("paid_inference", true)
      .where { amount > inference_invoiced_amount }.distinct.select_map(:project_id)
    project_ids |= Invoice.where(billing_kind: "inference_usage", status: "unpaid").select_map(:project_id)
    project_ids.each do |project_id|
      bud Prog::CollectInferenceUsage, {"project_id" => project_id}, "collect"
    end
    hop_wait_collections
  end

  label def wait_collections
    reap(:wait)
  end

  label def collect
    project = Project[frame.fetch("project_id")]
    if project
      # Strand executes labels inside a transaction. Only after it commits may
      # the adapter commit its request reservation and contact the payment API.
      # If the process stops before this callback, the next scan retries unpaid
      # invoices. Existing invoices do not depend on fresh billing/FX lookups.
      DB.after_commit do
        Invoice.where(project_id: project.id, billing_kind: "inference_usage", status: "unpaid").each do |invoice|
          InferenceUsageCollection.collect!(invoice)
        rescue => ex
          Clog.emit("Inference usage collection failed", Util.exception_to_hash(ex, into: {invoice_id: invoice.id}))
        end
      end

      unless project.invoices_dataset.where(billing_kind: "inference_usage", status: "unpaid").any?
        eur_rate = if project.billing_info&.country&.in_eu_vat?
          response = Excon.get("https://api.frankfurter.app/latest?from=USD&to=EUR", expects: 200,
            connect_timeout: 5, read_timeout: 5, write_timeout: 5)
          JSON.parse(response.body).fetch("rates").fetch("EUR")
        end
        InferenceUsageBilling.settle!(project:, eur_rate:)
      end
    end
    pop "inference usage collected"
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    Clog.emit("Inference usage collection failed", Util.exception_to_hash(ex, into: {project_id: frame["project_id"]}))
    pop "inference usage collection will retry"
  end
end
