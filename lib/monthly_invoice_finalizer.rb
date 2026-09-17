# frozen_string_literal: true

require "date"
require "excon"
require "json"

class MonthlyInvoiceFinalizer
  # Earlier invoices require a delivery-history audit before explicit backfill.
  FIRST_AUTOMATIC_MONTH = Date.new(2026, 9, 1)

  def self.due_months(now: Time.now)
    month = FIRST_AUTOMATIC_MONTH
    current_month = Date.new(now.utc.year, now.utc.month, 1)
    months = []
    while month < current_month
      months << month
      month >>= 1
    end
    months
  end

  def initialize(month:, project_ids: [], eur_rate: nil, dry_run: false, now: Time.now)
    @month = Date.new(month.year, month.month, 1)
    @begin_time = Time.utc(@month.year, @month.month, 1)
    next_month = @month >> 1
    @end_time = Time.utc(next_month.year, next_month.month, 1)
    raise ArgumentError, "Only completed months can be finalized" if @end_time > now

    @project_ids = project_ids
    @eur_rate = eur_rate
    @dry_run = dry_run
  end

  def run
    invoices = Invoice.where(begin_time: @begin_time, end_time: @end_time, billing_kind: "standard")
    project_ids = candidate_project_ids
    result = {month: @month.strftime("%Y-%m"), projects: project_ids.length, created: 0, processed: 0, failed: 0, dry_run: @dry_run}
    return result if @dry_run

    project_ids.each do |project_id|
      invoice = invoices.where(project_id:).first
      unless invoice
        @eur_rate ||= fetch_eur_rate
        invoice = InvoiceGenerator.new(@begin_time, @end_time, save_result: true, project_ids: [project_id], eur_rate: @eur_rate).run.first
        result[:created] += 1 if invoice
        invoice ||= invoices.where(project_id:).first
      end
      next unless invoice

      if invoice.status == "unpaid"
        invoice.charge
      elsif %w[paid below_minimum_threshold waiting_transfer].include?(invoice.status)
        invoice.send_success_email
      end
      result[:processed] += 1
    rescue => ex
      result[:failed] += 1
      Clog.emit("Monthly invoice finalization failed", {project_id:, month: result[:month], error_class: ex.class.name})
    end
    Clog.emit("Monthly invoice finalization completed", result)
    result
  end

  def candidate_project_ids
    invoices = Invoice.where(begin_time: @begin_time, end_time: @end_time, billing_kind: "standard")
    candidates = BillingRecord.exclude(Sequel.pg_jsonb_op(:resource_tags).contains({"paid_inference" => true}))
      .where { |br| Sequel.pg_range(br.span).overlaps(Sequel.pg_range(@begin_time...@end_time)) }
      .select_map(:project_id).uniq
    project_ids = candidates | invoices.select_map(:project_id)
    project_ids &= @project_ids unless @project_ids.empty?
    project_ids
  end

  def fetch_eur_rate
    response = Excon.get("https://api.frankfurter.app/latest?from=USD&to=EUR", expects: 200,
      connect_timeout: 5, read_timeout: 5, write_timeout: 5)
    rate = Float(JSON.parse(response.body).fetch("rates").fetch("EUR"))
    raise "Invalid USD to EUR exchange rate" unless rate.finite? && rate.positive?

    rate
  end
end
