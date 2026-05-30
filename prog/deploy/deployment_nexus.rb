# frozen_string_literal: true

require "shellwords"

class Prog::Deploy::DeploymentNexus < Prog::Base
  subject_is :deploy_deployment

  def self.assemble(app, trigger: "manual")
    DB.transaction do
      deployment = DeployDeployment.create(app_id: app.id, status: "queued", trigger:)
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
    deploy_deployment.update(status: "building", updated_at: Time.now)
    app.update(status: "deploying", updated_at: Time.now)

    vm.sshable.cmd("sudo bash -s", stdin: remote_setup_script, log: false, timeout: 30)
    hop_poll_remote_build
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
      configure_dns_record
      deploy_deployment.update(status: "live", finished_at: Time.now, updated_at: Time.now)
      app.update(status: "live", failure_message: nil, updated_at: Time.now)
      pop "deploy completed"
    else
      mark_failed(StandardError.new("Remote build failed. Check deployment logs."))
    end
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
    return unless Config.deploy_service_project_id && Config.deploy_service_hostname && vm.ip4_string

    zone = DnsZone.ensure_service_zone(project_id: Config.deploy_service_project_id, name: Config.deploy_service_hostname)
    return unless zone

    zone.delete_record(record_name: app.public_hostname)
    zone.insert_record(record_name: app.public_hostname, type: "A", ttl: 60, data: vm.ip4_string)
  end

  def mark_failed(ex)
    Clog.emit("LayerRail Deploy failed", {deploy_failed: {app_ubid: app&.ubid, deployment_ubid: deploy_deployment&.ubid, error_class: ex.class.name, error_message: ex.message}})
    message = ex.message.to_s.slice(0, 1000)
    log = app&.reload&.vm ? remote_deploy_log : deploy_deployment&.log.to_s
    deploy_deployment.update(status: "failed", failure_message: message, log:, finished_at: Time.now, updated_at: Time.now) if deploy_deployment
    app.update(status: "failed", failure_message: message, updated_at: Time.now) if app
    pop "deploy failed"
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
    <<~BASH
      set -euo pipefail

      APP_ID=#{sh(app.ubid)}
      DEPLOYMENT_ID=#{sh(deploy_deployment.ubid)}
      APP_HOST=#{sh(app.public_hostname)}
      REPOSITORY=#{sh(app.repository)}
      BRANCH=#{sh(app.branch)}
      ROOT_DIRECTORY=#{sh(app.root_directory.to_s)}
      OUTPUT_DIRECTORY=#{sh(app.output_directory.to_s)}
      APP_PORT=#{app.app_port.to_i}
      GITHUB_TOKEN=#{sh(access_token)}
      INSTALL_COMMAND=$(cat <<'LAYERRAIL_INSTALL_COMMAND'
      #{app.install_command}
      LAYERRAIL_INSTALL_COMMAND
      )
      BUILD_COMMAND=$(cat <<'LAYERRAIL_BUILD_COMMAND'
      #{app.build_command}
      LAYERRAIL_BUILD_COMMAND
      )
      START_COMMAND=$(cat <<'LAYERRAIL_START_COMMAND'
      #{app.start_command}
      LAYERRAIL_START_COMMAND
      )

      export DEBIAN_FRONTEND=noninteractive
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates curl git nginx build-essential
      NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
      if [ "$NODE_MAJOR" -lt 20 ]; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y nodejs
      fi

      APP_HOME="/opt/layerrail/apps/$APP_ID"
      RELEASE_DIR="$APP_HOME/releases/$DEPLOYMENT_ID"
      sudo install -d -m 0755 -o layerrail -g layerrail "$APP_HOME" "$APP_HOME/releases"
      rm -rf "$RELEASE_DIR"
      mkdir -p "$RELEASE_DIR"

      BASIC_AUTH="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
      git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $BASIC_AUTH" clone --depth 1 --branch "$BRANCH" "https://github.com/$REPOSITORY.git" "$RELEASE_DIR/src"
      unset GITHUB_TOKEN BASIC_AUTH
      sed -i 's/^GITHUB_TOKEN=.*/GITHUB_TOKEN=redacted/' "$0" || true

      cd "$RELEASE_DIR/src"
      if [ -n "$ROOT_DIRECTORY" ]; then
        cd "$ROOT_DIRECTORY"
      fi

      cat > "$RELEASE_DIR/app.env" <<'LAYERRAIL_ENV'
      PORT=#{app.app_port.to_i}
      #{remote_env_lines}
      LAYERRAIL_ENV

      set -a
      . "$RELEASE_DIR/app.env"
      set +a

      if [ -n "$INSTALL_COMMAND" ]; then
        bash -lc "$INSTALL_COMMAND"
      fi
      if [ -n "$BUILD_COMMAND" ]; then
        bash -lc "$BUILD_COMMAND"
      fi

      sudo rm -f /etc/nginx/sites-enabled/default

      if [ -n "$OUTPUT_DIRECTORY" ]; then
        DIST_DIR="$(pwd)/$OUTPUT_DIRECTORY"
        test -d "$DIST_DIR"
        sudo tee "/etc/nginx/sites-available/layerrail-$APP_ID" > /dev/null <<NGINX
      server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name $APP_HOST _;
        root $DIST_DIR;
        index index.html;

        location / {
          try_files \\$uri \\$uri/ /index.html;
        }
      }
      NGINX
      else
        if [ -z "$START_COMMAND" ]; then
          START_COMMAND="npm start"
        fi
        cat > "$APP_HOME/start-$DEPLOYMENT_ID.sh" <<START_SCRIPT
      #!/usr/bin/env bash
      set -euo pipefail
      cd "$(pwd)"
      set -a
      . "$RELEASE_DIR/app.env"
      set +a
      exec bash -lc $(printf "%q" "$START_COMMAND")
      START_SCRIPT
        chmod 0755 "$APP_HOME/start-$DEPLOYMENT_ID.sh"

        sudo tee "/etc/systemd/system/#{app_unit}" > /dev/null <<APP_SERVICE
      [Unit]
      Description=LayerRail app $APP_ID
      After=network-online.target
      Wants=network-online.target

      [Service]
      User=layerrail
      Group=layerrail
      WorkingDirectory=$(pwd)
      EnvironmentFile=$RELEASE_DIR/app.env
      Restart=always
      RestartSec=5
      ExecStart=/usr/bin/env bash $APP_HOME/start-$DEPLOYMENT_ID.sh

      [Install]
      WantedBy=multi-user.target
      APP_SERVICE

        sudo systemctl daemon-reload
        sudo systemctl enable --now #{app_unit}
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
          proxy_pass http://127.0.0.1:$APP_PORT;
        }
      }
      NGINX
      fi

      sudo ln -sf "/etc/nginx/sites-available/layerrail-$APP_ID" "/etc/nginx/sites-enabled/layerrail-$APP_ID"
      sudo nginx -t
      sudo systemctl reload nginx || sudo systemctl restart nginx
    BASH
  end

  def remote_env_lines
    app.variables.map { "#{it.key}=#{sh(it.value)}" }.join("\n")
  end

  def sh(value)
    Shellwords.escape(value.to_s)
  end
end
