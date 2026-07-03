# frozen_string_literal: true

class Prog::Monitoring::UptimeCheckNexus < Prog::Base
  subject_is :uptime_check

  def self.assemble(uptime_check)
    Strand.create_with_id(uptime_check, prog: "Monitoring::UptimeCheckNexus", label: "start", stack: [{subject_id: uptime_check.id}])
  end

  label def start
    when_destroy_set? { hop_destroy }
    uptime_check.ensure_billing_record!
    hop_wait
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    uptime_check.update(state: "down", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Uptime check setup failed", Util.exception_to_hash(ex).merge(uptime_check_id: uptime_check.id))
    nap 30 * 60
  end

  label def wait
    when_destroy_set? { hop_destroy }
    unless uptime_check.enabled
      uptime_check.update(state: "paused", updated_at: Time.now) unless uptime_check.state == "paused"
      nap uptime_check.interval_seconds
    end

    uptime_check.run_check!
    uptime_check.evaluate_alerts!
    nap uptime_check.interval_seconds
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    uptime_check.update(state: "down", last_error: ex.message, updated_at: Time.now)
    Clog.emit("Uptime check failed", Util.exception_to_hash(ex).merge(uptime_check_id: uptime_check.id))
    nap uptime_check.interval_seconds
  end

  label def destroy
    decr_destroy
    BillingRecord.finalize_active_for_resource(uptime_check)
    uptime_check.monitoring_alerts.each { BillingRecord.finalize_active_for_resource(it) }
    uptime_check.destroy
    pop "uptime check destroyed"
  end
end
