# frozen_string_literal: true

require "timeout"

class Prog::FinalizeMonthlyInvoices < Prog::Base
  label def wait
    if frame["next_scan_at"]
      delay = Time.parse(frame["next_scan_at"]) - Time.now
      nap delay.ceil if delay.positive?
    end
    update_stack({"next_scan_at" => (Time.now + 60 * 60).utc.iso8601})
    MonthlyInvoiceFinalizer.due_months.each do |month|
      bud Prog::FinalizeMonthlyInvoices, {"month" => month.to_s}, "finalize"
    end
    hop_wait_finalizations
  end

  label def wait_finalizations
    reap(:wait, nap: 10)
  end

  label def finalize
    month = Date.iso8601(frame.fetch("month"))
    MonthlyInvoiceFinalizer.new(month:).candidate_project_ids.each do |project_id|
      bud Prog::FinalizeMonthlyInvoices, {"month" => month.to_s, "project_id" => project_id}, "finalize_project"
    end
    hop_wait_projects
  end

  label def wait_projects
    reap(:finish, nap: 10)
  end

  label def finish
    pop "monthly invoices finalized"
  end

  label def finalize_project
    month = Date.iso8601(frame.fetch("month"))
    project_id = frame.fetch("project_id")
    DB.after_commit do
      # Each callback owns one project and finishes before the dispatcher's
      # 91-second watchdog and the strand's 120-second lease can expire.
      Timeout.timeout(75) { MonthlyInvoiceFinalizer.new(month:, project_ids: [project_id]).run }
    rescue => ex
      Clog.emit("Monthly invoice worker failed", {month: month.to_s, project_id:, error_class: ex.class.name})
    end
    pop "project monthly invoice finalized"
  end
end
