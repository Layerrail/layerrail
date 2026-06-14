# frozen_string_literal: true

require "json"
require "shellwords"

class Prog::Deploy::DeploymentNexus < Prog::Base
  subject_is :deploy_deployment

  def self.assemble(app, trigger: "manual", commit_sha: nil, commit_message: nil, image_ref: nil, source_ref: nil)
    DB.transaction do
      deployment = DeployDeployment.create(app_id: app.id, status: "queued", trigger:, commit_sha:, commit_message:, image_ref:, source_ref:)
      Strand.create_with_id(deployment, prog: "Deploy::DeploymentNexus", label: "start")
      deployment
    end
  end

  label def start
    fail "LayerRail Deploy is disabled" unless Config.deploy_enabled

    deploy_deployment.update(status: "provisioning", started_at: Time.now, updated_at: Time.now)
    app.update(status: "provisioning", failure_message: nil, updated_at: Time.now)
    hop_wait_vm if app.vm

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      app.project_id,
      unix_user: "layerrail",
      sshable_unix_user: "layerrail",
      name: "deploy-#{app.name}",
      size: app.vm_size,
      location_id: app.location_id,
      boot_image: Config.default_boot_image_name,
      enable_ip4: true,
      arch: "x64",
    )
    app.update(vm_id: vm_st.subject.id, updated_at: Time.now)
    hop_wait_vm
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    mark_failed(ex)
  end

  label def wait_vm
    vm = app.reload.vm
    nap 10 unless vm&.display_state == "running" && vm.sshable&.host

    begin
      vm.sshable.cmd("true", timeout: 10)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS
      nap 10
    end

    hop_start_remote_build
  end

  label def start_remote_build
    deploy_deployment.update(status: "building", image_ref: release_image_ref, source_ref: deploy_source_ref, updated_at: Time.now)
    app.update(status: "deploying", updated_at: Time.now)

    configure_dns_record
    vm.sshable.cmd("sudo bash -s", stdin: remote_setup_script, log: false, timeout: 30)
    hop_poll_remote_build
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    mark_failed(ex)
  end

  label def poll_remote_build
    status = remote_service_status
    log = remote_deploy_log
    deploy_deployment.update(log:, updated_at: Time.now)

    if status.fetch(:active_state) == "activating" || status.fetch(:sub_state) == "running"
      nap 10
    elsif status.fetch(:result) == "success" && %w[dead exited].include?(status.fetch(:sub_state))
      deploy_deployment.update(status: "live", finished_at: Time.now, updated_at: Time.now)
      app.update(status: "live", failure_message: nil, updated_at: Time.now)
      pop "deploy completed"
    else
      mark_failed(StandardError.new("Remote build failed. Check deployment logs."))
    end
  rescue Prog::Base::FlowControl
    raise
  rescue => ex
    mark_failed(ex)
  end

  private

  def app
    @app ||= deploy_deployment.app
  end

  def installation
    @installation ||= app.installation
  end

  def vm
    @vm ||= app.reload.vm
  end

  def deploy_unit
    "layerrail-deploy-#{deploy_deployment.ubid}.service"
  end

  def app_unit
    "layerrail-app-#{app.ubid}.service"
  end

  def remote_service_status
    output = vm.sshable.cmd("systemctl show -p ActiveState -p SubState -p Result --value :unit || true", unit: deploy_unit, timeout: 10)
    active_state, sub_state, result = output.split("\n", 3).map(&:to_s)
    {active_state:, sub_state:, result:}
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS
    {active_state: "activating", sub_state: "running", result: ""}
  end

  def remote_deploy_log
    log = vm.sshable.cmd("journalctl -u :unit --no-pager -n 240 || true", unit: deploy_unit, timeout: 20, log: false).to_s
    (log.length > 60_000) ? log[-60_000, 60_000] : log
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS
    deploy_deployment.log.to_s
  end

  def configure_dns_record
    return unless vm.ip4_string

    if Config.deploy_service_project_id && Config.deploy_service_hostname && app.public_hostname.end_with?(".#{Config.deploy_service_hostname}")
      zone = DnsZone.ensure_service_zone(project_id: Config.deploy_service_project_id, name: Config.deploy_service_hostname)
      if zone
        zone.delete_record(record_name: app.public_hostname)
        zone.insert_record(record_name: app.public_hostname, type: "A", ttl: 60, data: vm.ip4_string)
      end
    end

    app.project.domain_registrations_dataset.where(status: "active", deploy_app_id: app.id).each do |domain_registration|
      domain_registration.sync_deploy_dns_record!(app)
    end
  end

  def mark_failed(ex)
    Clog.emit("LayerRail Deploy failed", {deploy_failed: {app_ubid: app&.ubid, deployment_ubid: deploy_deployment&.ubid, error_class: ex.class.name, error_message: ex.message}})
    message = ex.message.to_s.slice(0, 1000)
    log = app&.reload&.vm ? remote_deploy_log : deploy_deployment&.log.to_s
    deploy_deployment.update(status: "failed", failure_message: message, log:, finished_at: Time.now, updated_at: Time.now) if deploy_deployment
    app.update(status: "failed", failure_message: message, updated_at: Time.now) if app
    notify_failure_safely(message)
    pop "deploy failed"
  end

  def notify_failure_safely(message)
    notify_failure(message)
  rescue => ex
    Clog.emit("deploy failure email failed", Util.exception_to_hash(ex, into: {deploy_failure_email_failed: {app_ubid: app&.ubid, deployment_ubid: deploy_deployment&.ubid}}))
  end

  def notify_failure(message)
    project = app.project
    receivers = project.accounts_dataset.select_map(:email).compact.uniq
    return if receivers.empty?

    Util.send_email(
      receivers,
      "LayerRail deployment failed: #{app.name}",
      greeting: "Hi,",
      body: [
        "The latest deployment for #{app.name} did not finish.",
        "Repository: #{app.repository}",
        "Branch: #{app.branch}",
        "Reason: #{message}",
        "Open the deployment to inspect the logs and redeploy when you're ready."
      ],
      button_title: "Open deployment",
      button_link: "#{Config.base_url}#{project.path}#{deploy_deployment.path}",
      author_name: "LayerRail"
    )
  end

  def github_access_token
    Github.installation_access_token(installation.installation_id)
  end

  def remote_setup_script
    script = remote_deploy_script(github_access_token)
    <<~BASH
      set -euo pipefail
      install -d -m 0755 /opt/layerrail/deployments
      cat > /opt/layerrail/deployments/#{deploy_deployment.ubid}.sh <<'LAYERRAIL_DEPLOY_SCRIPT'
      #{script}
      LAYERRAIL_DEPLOY_SCRIPT
      chown layerrail:layerrail /opt/layerrail/deployments/#{deploy_deployment.ubid}.sh
      chmod 0700 /opt/layerrail/deployments/#{deploy_deployment.ubid}.sh
      cat > /etc/systemd/system/#{deploy_unit} <<'LAYERRAIL_DEPLOY_UNIT'
      [Unit]
      Description=LayerRail Deploy #{deploy_deployment.ubid}
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      User=layerrail
      Group=layerrail
      ExecStart=/usr/bin/env bash /opt/layerrail/deployments/#{deploy_deployment.ubid}.sh

      [Install]
      WantedBy=multi-user.target
      LAYERRAIL_DEPLOY_UNIT
      systemctl daemon-reload
      systemctl start --no-block #{deploy_unit}
    BASH
  end

  def remote_deploy_script(access_token)
    fail "LayerRail Deploy container registry is not configured" unless deploy_registry_configured?

    <<~BASH
      set -euo pipefail

      APP_ID=#{sh(app.ubid)}
      DEPLOYMENT_ID=#{sh(deploy_deployment.ubid)}
      APP_HOST=#{sh(app.public_hostname)}
      REPOSITORY=#{sh(app.repository)}
      BRANCH=#{sh(app.branch)}
      ROOT_DIRECTORY=#{sh(app.root_directory.to_s)}
      BUILD_IMAGE=#{build_image? ? 1 : 0}
      BUILD_CACHE=#{app.build_cache_enabled ? 1 : 0}
      APP_PORT=#{app.app_port.to_i}
      UPSTREAM_PORT=#{app.app_port.to_i}
      CONTAINER_PORT=#{deploy_container_port}
      IMAGE_REF=#{sh(release_image_ref)}
      LATEST_IMAGE_REF=#{sh(deploy_latest_image_ref)}
      REGISTRY_HOST=#{sh(Config.deploy_container_registry_host)}
      REGISTRY_USERNAME=#{sh(Config.deploy_container_registry_username)}
      REGISTRY_PASSWORD=#{sh(Config.deploy_container_registry_password)}
      GITHUB_TOKEN=#{sh(access_token)}

      export DEBIAN_FRONTEND=noninteractive
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates curl git nginx docker.io
      sudo systemctl enable --now docker

      write_deploy_page() {
        local title="$1"
        local message="$2"
        sudo install -d -m 0755 /var/www/layerrail-deploy
        sudo tee /var/www/layerrail-deploy/index.html > /dev/null <<HTML
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>$title - LayerRail Deploy</title>
        <style>
          :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #FEFDFE; color: #101828; }
          main { width: min(720px, calc(100vw - 32px)); text-align: center; }
          .mark { width: 54px; height: 54px; margin: 0 auto 24px; border-radius: 16px; background: #8B67F2; box-shadow: 0 18px 40px rgba(139, 103, 242, .28); }
          h1 { margin: 0; font-size: clamp(32px, 5vw, 56px); line-height: 1; letter-spacing: 0; }
          p { margin: 18px auto 0; max-width: 560px; color: #667085; font-size: 18px; line-height: 1.6; }
          .host { margin-top: 28px; display: inline-flex; border: 1px solid #EBE9F1; border-radius: 999px; padding: 10px 16px; color: #5A3A38; background: white; }
        </style>
      </head>
      <body>
        <main>
          <div class="mark" aria-hidden="true"></div>
          <h1>$title</h1>
          <p>$message</p>
          <div class="host">$APP_HOST</div>
        </main>
      </body>
      </html>
      HTML
        sudo tee "/etc/nginx/sites-available/layerrail-$APP_ID" > /dev/null <<NGINX
      server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name $APP_HOST _;
        root /var/www/layerrail-deploy;
        index index.html;
      }
      NGINX
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo ln -sf "/etc/nginx/sites-available/layerrail-$APP_ID" "/etc/nginx/sites-enabled/layerrail-$APP_ID"
        sudo nginx -t
        sudo systemctl reload nginx || sudo systemctl restart nginx
      }

      deploy_failed() {
        local exit_code=$?
        trap - ERR
        write_deploy_page "Deployment failed" "The latest deployment did not finish. Open the LayerRail console to inspect the build log and redeploy."
        exit "$exit_code"
      }

      trap deploy_failed ERR
      write_deploy_page "Deployment in progress" "LayerRail is preparing this application. The page will update automatically when the deployment is live."

      APP_HOME="/opt/layerrail/apps/$APP_ID"
      RELEASE_DIR="$APP_HOME/releases/$DEPLOYMENT_ID"
      sudo install -d -m 0755 -o layerrail -g layerrail "$APP_HOME" "$APP_HOME/releases"
      rm -rf "$RELEASE_DIR"
      mkdir -p "$RELEASE_DIR"

      if [ "$BUILD_IMAGE" = "1" ]; then
        BASIC_AUTH="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
        git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $BASIC_AUTH" clone --depth 1 --branch "$BRANCH" "https://github.com/$REPOSITORY.git" "$RELEASE_DIR/src"
      fi
      unset GITHUB_TOKEN BASIC_AUTH
      sed -i 's/^GITHUB_TOKEN=.*/GITHUB_TOKEN=redacted/' "$0" || true

      BUILD_CONTEXT="$RELEASE_DIR/src"
      if [ "$BUILD_IMAGE" = "1" ]; then
        cd "$RELEASE_DIR/src"
        if [ -n "$ROOT_DIRECTORY" ]; then
          cd "$ROOT_DIRECTORY"
          BUILD_CONTEXT="$(pwd)"
        fi
      fi

      cat > "$RELEASE_DIR/app.env" <<'LAYERRAIL_ENV'
      PORT=#{app.app_port.to_i}
      #{remote_env_lines}
      LAYERRAIL_ENV

      printf '%s' "$REGISTRY_PASSWORD" | sudo docker login "$REGISTRY_HOST" --username "$REGISTRY_USERNAME" --password-stdin
      sed -i 's/^REGISTRY_PASSWORD=.*/REGISTRY_PASSWORD=redacted/' "$0" || true

      if [ "$BUILD_IMAGE" = "1" ]; then
        cat > "$RELEASE_DIR/Dockerfile.layerrail" <<'LAYERRAIL_DOCKERFILE'
      #{deploy_dockerfile}
      LAYERRAIL_DOCKERFILE
        if [ "$BUILD_CACHE" = "1" ]; then
          sudo docker pull "$LATEST_IMAGE_REF" || true
          CACHE_ARGS=(--cache-from "$LATEST_IMAGE_REF")
        else
          CACHE_ARGS=()
        fi
        sudo env DOCKER_BUILDKIT=1 docker build --pull "${CACHE_ARGS[@]}" -t "$IMAGE_REF" -t "$LATEST_IMAGE_REF" -f "$RELEASE_DIR/Dockerfile.layerrail" "$BUILD_CONTEXT"
        sudo docker push "$IMAGE_REF"
        sudo docker push "$LATEST_IMAGE_REF"
      fi

      sudo docker pull "$IMAGE_REF"

      sudo tee "/etc/systemd/system/#{app_unit}" > /dev/null <<APP_SERVICE
      [Unit]
      Description=LayerRail app $APP_ID
      After=network-online.target
      Wants=network-online.target

      [Service]
      Restart=always
      RestartSec=5
      ExecStartPre=-/usr/bin/docker rm -f layerrail-app-$APP_ID
      ExecStart=/usr/bin/docker run --rm --name layerrail-app-$APP_ID --env-file $RELEASE_DIR/app.env -p 127.0.0.1:$UPSTREAM_PORT:$CONTAINER_PORT $IMAGE_REF
      ExecStop=/usr/bin/docker stop layerrail-app-$APP_ID

      [Install]
      WantedBy=multi-user.target
      APP_SERVICE

      sudo systemctl daemon-reload
      sudo systemctl enable #{app_unit}
      sudo systemctl restart #{app_unit}
      sudo rm -f /etc/nginx/sites-enabled/default
      sudo tee "/etc/nginx/sites-available/layerrail-$APP_ID" > /dev/null <<NGINX
      server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name $APP_HOST _;

        location / {
          proxy_set_header Host \\$host;
          proxy_set_header X-Real-IP \\$remote_addr;
          proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \\$scheme;
          proxy_pass http://127.0.0.1:$UPSTREAM_PORT;
        }
      }
      NGINX

      sudo ln -sf "/etc/nginx/sites-available/layerrail-$APP_ID" "/etc/nginx/sites-enabled/layerrail-$APP_ID"
      sudo nginx -t
      sudo systemctl reload nginx || sudo systemctl restart nginx
      sleep 3
      sudo systemctl is-active --quiet #{app_unit}
      echo "LayerRail image deployed: $IMAGE_REF"
    BASH
  end

  def remote_env_lines
    app.variables.map { "#{it.key}=#{it.value.to_s.gsub(/\r?\n/, "\\n")}" }.join("\n")
  end

  def deploy_registry_configured?
    Config.deploy_container_registry_host && Config.deploy_container_registry_repository &&
      Config.deploy_container_registry_username && Config.deploy_container_registry_password
  end

  def deploy_image_ref
    repository = Config.deploy_container_registry_repository.to_s.delete_prefix("/").delete_suffix("/")
    tag = "#{app.ubid.to_s.delete_prefix("da")}-#{deploy_deployment.ubid.to_s.delete_prefix("dd")}"
    "#{Config.deploy_container_registry_host}/#{repository}:#{tag}"
  end

  def deploy_latest_image_ref
    repository = Config.deploy_container_registry_repository.to_s.delete_prefix("/").delete_suffix("/")
    tag = "#{app.ubid.to_s.delete_prefix("da")}-latest"
    "#{Config.deploy_container_registry_host}/#{repository}:#{tag}"
  end

  def release_image_ref
    deploy_deployment.image_ref.to_s.empty? ? deploy_image_ref : deploy_deployment.image_ref
  end

  def build_image?
    deploy_deployment.trigger != "rollback"
  end

  def deploy_source_ref
    deploy_deployment.source_ref.to_s.empty? ? "#{app.repository}@#{app.branch}" : deploy_deployment.source_ref
  end

  def deploy_container_port
    app.output_directory.to_s.empty? ? app.app_port.to_i : 80
  end

  def deploy_dockerfile
    case app.framework
    when "static"
      static_dockerfile
    when "node"
      dynamic_dockerfile("node:22-bookworm-slim", packages: "bash ca-certificates", default_start: "npm start")
    when "python"
      dynamic_dockerfile("python:3.12-slim", packages: "bash ca-certificates build-essential", default_start: "gunicorn app:app --bind 0.0.0.0:$PORT")
    when "ruby"
      dynamic_dockerfile("ruby:3.3-slim", packages: "bash ca-certificates build-essential", default_start: "bundle exec puma -b tcp://0.0.0.0:$PORT")
    when "php", "laravel"
      php_dockerfile
    when "rust"
      dynamic_dockerfile("rust:1-bookworm", packages: "bash ca-certificates", default_start: "./target/release/app")
    when "go"
      dynamic_dockerfile("golang:1.23-bookworm", packages: "bash ca-certificates", default_start: "./layerrail-app")
    else
      dynamic_dockerfile("ubuntu:24.04", packages: "ca-certificates curl bash", default_start: "bash")
    end
  end

  def static_dockerfile
    install = app.install_command.to_s.strip
    build = app.build_command.to_s.strip
    output = app.output_directory.to_s.strip.empty? ? "dist" : app.output_directory.to_s.strip
    <<~DOCKERFILE
      FROM node:22-bookworm-slim AS build
      WORKDIR /app
      COPY . .
      #{docker_run(install)}
      #{docker_run(build)}

      FROM nginx:1.27-alpine
      COPY --from=build /app/#{output} /usr/share/nginx/html
      EXPOSE 80
    DOCKERFILE
  end

  def php_dockerfile
    install = app.install_command.to_s.strip
    build = app.build_command.to_s.strip
    start = app.start_command.to_s.strip
    start = "php -S 0.0.0.0:$PORT -t public" if start.empty?
    <<~DOCKERFILE
      FROM composer:2 AS composer
      FROM php:8.3-cli-bookworm
      WORKDIR /app
      ENV PORT=#{app.app_port.to_i}
      RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates git unzip libzip-dev libpq-dev default-mysql-client && docker-php-ext-install zip pdo_mysql pdo_pgsql && rm -rf /var/lib/apt/lists/*
      COPY --from=composer /usr/bin/composer /usr/bin/composer
      COPY . .
      #{docker_run(install)}
      #{docker_run(build)}
      EXPOSE #{app.app_port.to_i}
      CMD #{["bash", "-lc", start].to_json}
    DOCKERFILE
  end

  def dynamic_dockerfile(base_image, packages:, default_start:)
    install = app.install_command.to_s.strip
    build = app.build_command.to_s.strip
    start = app.start_command.to_s.strip
    start = default_start if start.empty?
    <<~DOCKERFILE
      FROM #{base_image}
      WORKDIR /app
      ENV PORT=#{app.app_port.to_i}
      #{docker_apt_install(packages)}
      COPY . .
      #{docker_run(install)}
      #{docker_run(build)}
      EXPOSE #{app.app_port.to_i}
      CMD #{["bash", "-lc", start].to_json}
    DOCKERFILE
  end

  def docker_apt_install(packages)
    packages = packages.to_s.strip
    return "" if packages.empty?

    "RUN if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y --no-install-recommends #{packages} && rm -rf /var/lib/apt/lists/*; fi"
  end

  def docker_run(command)
    command = command.to_s.strip
    return "" if command.empty?

    "RUN bash -lc #{Shellwords.escape(command)}"
  end

  def sh(value)
    Shellwords.escape(value.to_s)
  end
end
