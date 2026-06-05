# frozen_string_literal: true

require_relative "../../common/lib/util"
require "logger"

class PostgresSetup
  # Per-service GOMEMLIMIT targets, sum kept under system-go_services.slice MemoryHigh=2G
  GO_SERVICES = {
    "prometheus" => "1024MiB",
    "wal-g" => "448MiB",
    "postgres_exporter" => "384MiB",
    "node_exporter" => "128MiB",
  }.freeze

  def initialize(version)
    @version = version
  end

  def install_packages
    # Check if the packages exist in the cache, if so, install them.
    if File.exist?("/var/cache/postgresql-packages/#{@version}")
      r "sudo install-postgresql-packages #{@version}"
    else
      install_packages_from_apt
    end
  end

  def install_packages_from_apt
    codename = r(". /etc/os-release && printf '%s' \"$VERSION_CODENAME\"").strip
    r "sudo install -d -m 0755 /etc/apt/keyrings"
    apt_update
    apt_install "ca-certificates curl gpg lsb-release acl prometheus prometheus-node-exporter prometheus-postgres-exporter pgbouncer"
    r "curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg.tmp"
    r "sudo mv /etc/apt/keyrings/postgresql.gpg.tmp /etc/apt/keyrings/postgresql.gpg"
    r "echo 'deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt #{codename}-pgdg main' | sudo tee /etc/apt/sources.list.d/pgdg.list"
    r "sudo mkdir -p /etc/postgresql-common"
    r "echo 'create_main_cluster = false' | sudo tee /etc/postgresql-common/createcluster.conf"
    apt_update
    apt_install "postgresql-#{@version} postgresql-client-#{@version} postgresql-contrib-#{@version}"
    r "sudo groupadd -f --system cert_readers"
    r "id -u prometheus >/dev/null 2>&1 || sudo useradd --system --home-dir /home/prometheus --shell /usr/sbin/nologin prometheus"
    r "sudo usermod -aG cert_readers postgres"
    r "sudo usermod -aG cert_readers prometheus"
    r "sudo install -d -o prometheus -g prometheus -m 0755 /home/prometheus /var/lib/prometheus"
    configure_exporter_services
  end

  def apt_update
    r "sudo env DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get update"
  end

  def apt_install(packages)
    r "sudo env DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::=--force-confold #{packages}"
  end

  def configure_exporter_services
    safe_write_to_file("/etc/systemd/system/node_exporter.service", <<~SERVICE)
      [Unit]
      Description=Prometheus Node Exporter
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=simple
      ExecStart=/bin/sh -c 'exec $(command -v prometheus-node-exporter || command -v node_exporter) --web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/node_exporter'
      Restart=always
      User=nobody
      Group=nogroup

      [Install]
      WantedBy=multi-user.target
    SERVICE

    safe_write_to_file("/etc/systemd/system/postgres_exporter.service", <<~SERVICE)
      [Unit]
      Description=Prometheus PostgreSQL Exporter
      After=postgresql.service

      [Service]
      Type=simple
      Environment=DATA_SOURCE_NAME=postgresql:///postgres?host=/var/run/postgresql&sslmode=disable
      ExecStart=/bin/sh -c 'exec $(command -v prometheus-postgres-exporter || command -v postgres_exporter) --web.listen-address=127.0.0.1:9187 --extend.query-path=/usr/local/share/postgresql/postgres_exporter_queries.yaml'
      Restart=always
      User=postgres
      Group=postgres

      [Install]
      WantedBy=multi-user.target
    SERVICE

    safe_write_to_file("/etc/systemd/system/prometheus.service", <<~SERVICE)
      [Unit]
      Description=Prometheus
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=simple
      User=prometheus
      Group=prometheus
      ExecStart=/bin/sh -c 'exec $(command -v prometheus) --config.file=/home/prometheus/prometheus.yml --web.config.file=/home/prometheus/web-config.yml --storage.tsdb.path=/var/lib/prometheus --web.listen-address=127.0.0.1:9090'
      Restart=always

      [Install]
      WantedBy=multi-user.target
    SERVICE

    r "sudo systemctl daemon-reload"
  end

  def configure_memory_overcommit(strict: false)
    if strict
      total_mem_kb = File.read("/proc/meminfo").match(/MemTotal:\s+(\d+)/)[1].to_i
      # 25% of memory is reserved for hugepages, which do not count towards the
      # commit limit, so only the remaining 75% is available for overcommit.
      non_hugepage_mem_kb = total_mem_kb * 0.75
      overcommit_kbytes = (non_hugepage_mem_kb * 0.8 + 2 * 1048576).round
      safe_write_to_file("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=#{overcommit_kbytes}\n")
    else
      r "sudo rm -f /etc/sysctl.d/99-overcommit.conf"
    end

    r "sudo sysctl --system"
  end

  def configure_tcp_keepalive
    safe_write_to_file("/etc/sysctl.d/99-tcp-keepalive.conf", <<~SYSCTL)
      net.ipv4.tcp_keepalive_time=30
      net.ipv4.tcp_keepalive_probes=3
      net.ipv4.tcp_keepalive_intvl=10
    SYSCTL
    r "sudo sysctl --system"
  end

  def configure_service_slice
    safe_write_to_file("/etc/systemd/system/system-go_services.slice", <<~SLICE)
      [Slice]
      MemoryHigh=2G
      MemoryMax=2560M
    SLICE
    GO_SERVICES.each do |svc, gomemlimit|
      r "mkdir -p /etc/systemd/system/#{svc}.service.d"
      safe_write_to_file("/etc/systemd/system/#{svc}.service.d/override.conf", <<~OVERRIDE)
        [Service]
        Slice=system-go_services.slice
        Environment=GOMEMLIMIT=#{gomemlimit}
      OVERRIDE
    end
    r "systemctl daemon-reload"
    # Apply cap so without restarting. Slice= and GOMEMLIMIT are load-time directives,
    # so only restart services not yet in slice.
    r "systemctl set-property system-go_services.slice MemoryHigh=2G MemoryMax=2560M"
    GO_SERVICES.each_key do |svc|
      current_slice = r("systemctl show #{svc}.service -p Slice --value", expect: [0, 1, 3, 4]).strip
      next if current_slice == "system-go_services.slice"
      r "systemctl try-restart #{svc}.service", expect: [0, 1, 3, 4, 5]
    end
  end

  def setup_data_directory
    r "chown postgres /dat"

    # Below commands are required for idempotency
    r "rm -rf /dat/#{@version}"
    r "rm -rf /etc/postgresql/#{@version}"

    r "sudo mkdir -p /etc/postgresql-common/createcluster.d"
    r "echo \"data_directory = '/dat/#{@version}/data'\" | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf"

    # Install to path postgres can access
    r "install -m 0755 #{File.expand_path("../bin/disk-full-check", __dir__).shellescape} /usr/local/sbin/disk-full-check"

    safe_write_to_file("/etc/systemd/system/disk-full-check@.service", <<~DISKFULL)
      [Unit]
      Wants=disk-full-check@%i.timer
      Description=Mitigate disk full scenarios

      [Service]
      Type=oneshot
      User=postgres
      ExecStart=/usr/local/sbin/disk-full-check %i

      [Install]
      WantedBy=multi-user.target
    DISKFULL

    safe_write_to_file("/etc/systemd/system/disk-full-check@.timer", <<~DISKFULL)
      [Unit]
      Description=Schedule disk full check

      [Timer]
      OnBootSec=30s
      OnUnitActiveSec=20s
      AccuracySec=1s
      Unit=disk-full-check@%i.service

      [Install]
      WantedBy=timers.target
    DISKFULL

    r "sudo systemctl daemon-reload"
    r "sudo systemctl enable --now disk-full-check@#{@version}.timer"
  end

  def create_cluster
    r "pg_createcluster #{@version} main --datadir=/dat/#{@version}/data --port=5432 --locale=C.UTF8"
    ensure_cluster_config_directories
  end

  def ensure_cluster_config_directories
    r "sudo mkdir -p /etc/postgresql/#{@version}/main/conf.d"
  end
end
