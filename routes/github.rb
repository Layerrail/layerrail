# frozen_string_literal: true

require "securerandom"
require "uri"

class Clover
  hash_branch("github") do |r|
    r.get web?, "callback" do
      no_authorization_needed
      oauth_code = typecast_params.str("code")
      installation_id = typecast_params.str("installation_id") || session.delete("github_installation_id")
      setup_action = typecast_params.str("setup_action")
      state = typecast_params.str("state")
      context = session["github_installation_context"].to_s == "deploy" ? "deploy" : "github"
      project_return_path = ->(project) { context == "deploy" ? "#{project.path}/deploy/create" : "#{project.path}/github" }
      clear_github_session = lambda do
        session.delete("github_installation_project_id")
        session.delete("github_installation_state")
        session.delete("github_installation_context")
      end

      if (installation = GithubInstallation.with_github_installation_id(installation_id))
        @project = installation.project
        authorize(context == "deploy" ? "Vm:create" : "Project:github", installation.project)
        clear_github_session.call
        if context == "deploy"
          flash["notice"] = "GitHub is already connected for LayerRail Deploy."
          r.redirect "#{installation.project.path}/deploy/create"
        end

        flash["notice"] = "GitHub runner integration is already enabled for #{installation.project.name} project."
        Clog.emit("GitHub installation already exists", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect installation, "/runner"
      end

      unless (@project = project = current_account.projects_dataset.with_pk(session["github_installation_project_id"]))
        flash["error"] = context == "deploy" ? "Start GitHub connection from the LayerRail Deploy import page." : "You should initiate the GitHub App installation request from the project's GitHub runner integration page."
        Clog.emit("GitHub callback failed due to lack of project in the session", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect "/project"
      end

      authorize(context == "deploy" ? "Vm:create" : "Project:github", project)

      if oauth_code
        expected_state = session.delete("github_installation_state")
        if expected_state && state != expected_state
          flash["error"] = "GitHub App installation failed because the authorization state did not match. Please try connecting the account again."
          Clog.emit("GitHub callback failed due to state mismatch", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
          r.redirect project_return_path.call(project)
        end
      end

      if setup_action == "request"
        clear_github_session.call
        flash["notice"] = "The GitHub App installation request is awaiting approval from the GitHub organization's administrator. As GitHub will redirect your admin back to the LayerRail console, the admin needs to have a LayerRail account with the necessary permissions to finalize the installation. Please invite the admin to your project if they don't have an account yet."
        Clog.emit("GitHub installation initiated by non-admin user", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect user_path
      end

      unless oauth_code
        if installation_id && Config.github_app_client_id
          state = SecureRandom.urlsafe_base64(24)
          session["github_installation_id"] = installation_id
          session["github_installation_state"] = state
          query = URI.encode_www_form(
            client_id: Config.github_app_client_id,
            redirect_uri: "#{Config.base_url}/github/callback",
            state:,
          )
          r.redirect "https://github.com/login/oauth/authorize?#{query}", 302
        end

        flash["error"] = "GitHub App installation failed because GitHub did not return an authorization code. Enable OAuth during installation for the GitHub App and try again."
        Clog.emit("GitHub callback failed due to missing oauth code", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect project_return_path.call(project)
      end

      code_response = Github.oauth_client.exchange_code_for_token(oauth_code)

      unless (access_token = code_response[:access_token])
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@layerrail.com"
        Clog.emit("GitHub callback failed due to lack of permission", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect project_return_path.call(project)
      end

      begin
        user_installations = Octokit::Client.new(access_token:).get("/user/installations")[:installations]
      rescue Octokit::Unauthorized => e
        installation_octokit_error = e
      end

      installation_response = if installation_id
        user_installations&.find { it[:id].to_s == installation_id }
      else
        unclaimed_installations = user_installations&.select do |it|
          next false if Config.github_app_id && it[:app_id].to_s != Config.github_app_id.to_s

          !GithubInstallation.with_github_installation_id(it[:id].to_s)
        end

        if unclaimed_installations&.one?
          installation_id = unclaimed_installations.first[:id].to_s
          unclaimed_installations.first
        elsif unclaimed_installations&.any?
          flash["error"] = "LayerRail found multiple unlinked GitHub App installations for your GitHub user. Please reconnect from GitHub and choose the account again."
          Clog.emit("GitHub callback failed due to ambiguous installation", {installation_failed: {count: unclaimed_installations.count, account_ubid: current_account.ubid}})
          r.redirect project_return_path.call(project)
        end
      end

      unless installation_response
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@layerrail.com"
        installation_failed = {id: installation_id, account_ubid: current_account.ubid}
        if installation_octokit_error
          Util.exception_to_hash(installation_octokit_error, into: installation_failed)
        end
        Clog.emit("GitHub callback failed due to lack of installation", {installation_failed:})
        r.redirect project_return_path.call(project)
      end

      unless project.active?
        flash["error"] = context == "deploy" ? "LayerRail Deploy GitHub connection is not allowed for inactive projects" : "GitHub runner integration is not allowed for inactive projects"
        Clog.emit("GitHub callback failed due to inactive project", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect project, "/dashboard"
      end

      installation = GithubInstallation.create(
        installation_id:,
        name: installation_response[:account][:login] || installation_response[:account][:name],
        type: installation_response[:account][:type],
        project_id: project.id,
      )

      clear_github_session.call
      if context == "deploy"
        flash["notice"] = "GitHub is connected for LayerRail Deploy. Choose a repository to import."
        r.redirect "#{project.path}/deploy/create"
      end

      flash["notice"] = "GitHub runner integration is enabled for #{project.name} project."
      r.redirect installation, "/runner"
    end
  end
end
