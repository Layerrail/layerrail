# frozen_string_literal: true

class Prog::CheckUsageAlerts < Prog::Base
  label def wait
    begin_time = Date.new(Time.now.year, Time.now.month, 1).to_time

    alerts = UsageAlert.eager(:project).where { last_triggered_at < begin_time }.all
    limits = UsageLimit.eager(:project, :user).all
    costs = {}

    limits.each do |usage_limit|
      cost = (costs[usage_limit.project_id] ||= usage_limit.project.current_invoice(since: begin_time).content["cost"])
      usage_limit.reconcile!(cost)
    rescue => ex
      Clog.emit("Failed to reconcile project usage limit", Util.exception_to_hash(ex).merge(usage_limit_id: usage_limit.id, project_id: usage_limit.project_id))
    end

    alerts.group_by(&:project).each do |project, project_alerts|
      cost = (costs[project.id] ||= project.current_invoice(since: begin_time).content["cost"])
      project_alerts.each do |alert|
        alert.trigger(cost) if cost > alert.limit
      end
    end

    nap 5 * 60
  end
end
