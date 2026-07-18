# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "usage-limit") do |r|
    r.web do
      authorize("Project:billing", @project)

      r.post true do
        handle_validation_failure("project/billing")
        new_limit = typecast_params.pos_int!("usage_limit")
        current_cost = @project.current_invoice(since: Time.utc(Time.now.year, Time.now.month)).content["cost"]

        if (usage_limit = @project.usage_limit_dataset.first)
          usage_limit.adjust!(new_limit, user_id: current_account_id, current_cost:) do
            audit_log(usage_limit, "update")
          end
          flash["notice"] = "Monthly usage limit updated."
        else
          DB.transaction do
            usage_limit = UsageLimit.create(
              project_id: @project.id,
              user_id: current_account_id,
              limit: new_limit,
              period_start: Date.new(Time.now.year, Time.now.month, 1),
            )
            audit_log(usage_limit, "create")
          end
          usage_limit.notify_safely(:set, current_cost:)
          usage_limit.reconcile!(current_cost)
          flash["notice"] = "Monthly usage limit set."
        end

        r.redirect billing_path
      end

      r.delete true do
        next unless (usage_limit = @project.usage_limit_dataset.first)

        current_cost = @project.current_invoice(since: Time.utc(Time.now.year, Time.now.month)).content["cost"]
        usage_limit.remove!(current_cost:) do
          audit_log(usage_limit, "destroy")
        end

        flash["notice"] = "Monthly usage limit removed."
        r.redirect billing_path
      end
    end
  end
end