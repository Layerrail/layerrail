# frozen_string_literal: true

class Clover
  hash_branch(:webhook_prefix, "github") do |r|
    r.post true do
      body = r.body.read
      next 401 unless check_signature(r.headers["x-hub-signature-256"], body)

      response.content_type = :json

      data = JSON.parse(body)
      case r.headers["x-github-event"]
      when "installation"
        handle_installation(data)
      when "workflow_job"
        handle_workflow_job(data)
      when "push"
        handle_push(data)
      when "pull_request"
        handle_pull_request(data)
      else
        error("Unhandled event")
      end
    end
  end

  def error(msg)
    {error: {message: msg}}
  end

  def success(msg)
    {message: msg}
  end

  def check_signature(signature, body)
    return false unless signature

    method, actual_digest = signature.split("=")
    expected_digest = OpenSSL::HMAC.hexdigest(method, Config.github_app_webhook_secret, body)
    Rack::Utils.secure_compare(actual_digest, expected_digest)
  end

  def handle_installation(data)
    installation = GithubInstallation.with_github_installation_id(data["installation"]["id"])
    case data["action"]
    when "deleted"
      return error("Unregistered installation") unless installation
      return error("Inactive project") unless installation.project.active?

      Prog::Github::DestroyGithubInstallation.assemble(installation)
      return success("GithubInstallation[#{installation.ubid}] deleted")
    end

    error("Unhandled installation action")
  end

  def handle_workflow_job(data)
    unless (installation = GithubInstallation.with_github_installation_id(data["installation"]["id"]))
      return error("Unregistered installation")
    end

    unless (job = data["workflow_job"])
      Clog.emit("No workflow_job in the payload", {workflow_job_missing: {installation_id: installation.id, action: data["action"]}})
      return error("No workflow_job in the payload")
    end

    job_labels = job.fetch("labels")

    if (label = job_labels.find { Github.runner_labels.key?(it) })
      actual_label = label
    elsif (custom_label = installation.custom_labels_dataset.first(name: job_labels))
      actual_label = custom_label.name
      label = custom_label.alias_for
    end

    repository_name = data["repository"]["full_name"]
    unless label
      if data["action"] == "completed"
        Clog.emit("Unmatched label", {
          unmatched_label: {
            repository_name:,
            labels: job_labels,
            started_in: Time.parse(job["started_at"]) - Time.parse(job["created_at"]),
            completed_in: job["completed_at"] ? (Time.parse(job["completed_at"]) - Time.parse(job["started_at"])) : nil,
            conclusion: job["conclusion"],
          },
        })
      end
      return error("Unmatched label")
    end

    if data["action"] == "queued"
      runner = Prog::Github::GithubRunnerNexus.assemble(
        installation,
        repository_name:,
        label:,
        actual_label:,
        default_branch: data["repository"]["default_branch"],
      ).subject

      return success("GithubRunner[#{runner.ubid}] created")
    end

    unless (runner_id = job.fetch("runner_id"))
      return error("A workflow_job without runner_id")
    end

    runner = installation.runners_dataset.first(
      repository_name:,
      runner_id:,
    )

    return error("Unregistered runner") unless runner

    runner.this.update(workflow_job: Sequel.pg_jsonb(job.except("steps")))

    case data["action"]
    when "in_progress"
      runner.log_duration("runner_started", Time.parse(job["started_at"]) - Time.parse(job["created_at"]))
      success("GithubRunner[#{runner.ubid}] picked job #{job.fetch("id")}")
    when "completed"
      runner.incr_destroy

      success("GithubRunner[#{runner.ubid}] deleted")
    else
      error("Unhandled workflow_job action")
    end
  end

  def handle_push(data)
    unless Config.deploy_enabled
      return error("LayerRail Deploy is disabled")
    end

    unless (installation = GithubInstallation.with_github_installation_id(data.dig("installation", "id")))
      return error("Unregistered installation")
    end

    repository_name = data.dig("repository", "full_name").to_s
    branch = data["ref"].to_s.delete_prefix("refs/heads/")
    return error("Unhandled ref") if repository_name.empty? || branch.empty? || branch == data["ref"].to_s

    apps = DeployApp.where(installation_id: installation.id, repository: repository_name, branch:, environment: "production", auto_deploy: true).all
    return success("No matching deploy apps") if apps.empty?

    deployed = 0
    skipped = 0
    apps.each do |app|
      in_flight = app.latest_deployment&.status
      if %w[queued provisioning building].include?(in_flight) || %w[provisioning deploying deleting].include?(app.display_state)
        skipped += 1
        next
      end

      Prog::Deploy::DeploymentNexus.assemble(
        app,
        trigger: "github_push",
        commit_sha: data["after"],
        commit_message: data.dig("head_commit", "message").to_s.slice(0, 1000)
      )
      deployed += 1
    end

    success("Triggered #{deployed} deploy app#{deployed == 1 ? "" : "s"}; skipped #{skipped}")
  end

  def handle_pull_request(data)
    return error("LayerRail Deploy is disabled") unless Config.deploy_enabled

    action = data["action"].to_s
    return error("Unhandled pull_request action") unless %w[opened reopened synchronize closed].include?(action)

    unless (installation = GithubInstallation.with_github_installation_id(data.dig("installation", "id")))
      return error("Unregistered installation")
    end

    pr = data["pull_request"] || {}
    repository_name = data.dig("repository", "full_name").to_s
    number = pr["number"] || data["number"]
    base_branch = pr.dig("base", "ref").to_s
    head_branch = pr.dig("head", "ref").to_s
    head_sha = pr.dig("head", "sha").to_s
    head_repository = pr.dig("head", "repo", "full_name").to_s
    return error("Invalid pull_request payload") if repository_name.empty? || number.to_s.empty? || base_branch.empty? || head_branch.empty?
    return success("Skipped fork pull request preview") unless head_repository.empty? || head_repository == repository_name

    production_apps = DeployApp.where(installation_id: installation.id, repository: repository_name, branch: base_branch, environment: "production", auto_deploy: true).all
    return success("No matching deploy apps") if production_apps.empty?

    handled = 0
    skipped = 0
    production_apps.each do |production_app|
      preview_key = "#{repository_name}:pr-#{number}"
      preview = DeployApp.where(project_id: production_app.project_id, production_app_id: production_app.id, preview_key:).first

      if action == "closed"
        if preview && !preview.display_state.start_with?("deleting")
          Prog::Deploy::AppNexus.assemble_destroy(preview)
          handled += 1
        end
        next
      end

      preview ||= create_preview_deploy_app(production_app, preview_key, number, head_branch)
      preview.update(branch: head_branch, updated_at: Time.now) if preview.branch != head_branch

      in_flight = preview.latest_deployment&.status
      if %w[queued provisioning building].include?(in_flight) || %w[provisioning deploying deleting].include?(preview.display_state)
        skipped += 1
        next
      end

      Prog::Deploy::DeploymentNexus.assemble(
        preview,
        trigger: "github_preview",
        commit_sha: head_sha.empty? ? nil : head_sha,
        commit_message: pr["title"].to_s.slice(0, 1000),
        source_ref: "#{repository_name}@#{head_branch}"
      )
      handled += 1
    end

    success("Handled #{handled} preview app#{handled == 1 ? "" : "s"}; skipped #{skipped}")
  end

  def create_preview_deploy_app(production_app, preview_key, number, head_branch)
    app = DeployApp.new_with_id(
      project_id: production_app.project_id,
      installation_id: production_app.installation_id,
      location_id: production_app.location_id,
      production_app_id: production_app.id,
      preview_key:,
      environment: "preview",
      name: preview_app_name(production_app, number),
      repository: production_app.repository,
      branch: head_branch,
      root_directory: production_app.root_directory,
      install_command: production_app.install_command,
      build_command: production_app.build_command,
      start_command: production_app.start_command,
      output_directory: production_app.output_directory,
      app_port: production_app.app_port,
      framework: production_app.framework,
      vm_size: production_app.vm_size,
      status: "idle"
    )
    app.hostname = "#{app.name}-#{app.ubid.to_s[2, 6]}.#{Config.deploy_service_hostname}"
    app.save_changes
    app
  end

  def preview_app_name(production_app, number)
    base = "#{production_app.name}-pr-#{number}".downcase.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").gsub(/\A-|-+\z/, "")
    base = "preview-pr-#{number}" if base.empty?
    base[0, 54].gsub(/-+\z/, "")
  end
end
