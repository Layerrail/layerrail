# frozen_string_literal: true

class UsageLimitEmail
  def self.deliver(usage_limit, event, current_cost:)
    new(usage_limit, current_cost).deliver(event)
  end

  def initialize(usage_limit, current_cost)
    @usage_limit = usage_limit
    @current_cost = current_cost.to_f
  end

  def deliver(event)
    subject, body, button_title = content(event)
    Util.send_email(
      usage_limit.user.email,
      subject,
      greeting:,
      body:,
      button_title:,
      button_link: "#{Config.base_url}#{usage_limit.project.path}/billing",
    )
  end

  private

  attr_reader :usage_limit, :current_cost

  def content(event)
    project_name = usage_limit.project.name
    project_id = usage_limit.project.ubid
    spend = money(current_cost)
    cap = money(usage_limit.limit)

    case event
    when :set
      [
        "Monthly usage limit set for project #{project_name}",
        [
          "A monthly usage limit of #{cap} has been set for project #{project_name} (#{project_id}).",
          "We will email you when usage reaches 80%, 90%, and 100% of this limit.",
          "At 100%, LayerRail temporarily stops the project's running services. No resources or data are deleted. Services start again only after you raise or remove the limit.",
        ],
        "View usage limit",
      ]
    when :updated
      [
        "Monthly usage limit updated for project #{project_name}",
        [
          "The monthly usage limit for project #{project_name} (#{project_id}) is now #{cap}.",
          "Current usage is #{spend}.",
          "Threshold notifications have been reset for the adjusted limit.",
        ],
        "View usage limit",
      ]
    when 80, 90
      urgency = (event == 90) ? "Please raise the limit now to avoid a service interruption." : "Your services are still running."
      [
        "Project #{project_name} has reached #{event}% of its usage limit",
        [
          "Project #{project_name} (#{project_id}) has used #{spend} of its #{cap} monthly usage limit.",
          urgency,
          "If usage reaches 100%, all running services in this project will be temporarily stopped until the limit is adjusted.",
        ],
        "Review usage",
      ]
    when 100
      [
        "Usage limit reached — services stopped for project #{project_name}",
        [
          "Project #{project_name} (#{project_id}) has used #{spend}, reaching its #{cap} monthly usage limit.",
          "LayerRail has temporarily stopped this project's running services and paused ongoing metered runtime charges. No resources or data were deleted.",
          "Raise or remove the usage limit to start the services again automatically.",
        ],
        "Adjust usage limit",
      ]
    when :resumed
      [
        "Services resumed for project #{project_name}",
        [
          "The usage limit for project #{project_name} (#{project_id}) was adjusted above its current usage of #{spend}.",
          "Services that LayerRail stopped at the limit are starting again automatically.",
        ],
        "View service status",
      ]
    when :removed
      [
        "Monthly usage limit removed for project #{project_name}",
        [
          "The monthly usage limit for project #{project_name} (#{project_id}) has been removed.",
          "Any services stopped by the usage limit are starting again automatically.",
        ],
        "View billing",
      ]
    else
      raise ArgumentError, "Unknown usage limit email event: #{event.inspect}"
    end
  end

  def greeting
    name = usage_limit.user.name.to_s.strip
    name.empty? ? "Hello," : "Hello #{name},"
  end

  def money(value)
    "$#{format("%.2f", value.to_f)}"
  end
end