# frozen_string_literal: true

class Prog::Vnet::UpdateLoadBalancerNode < Prog::Base
  subject_is :vm

  def load_balancer
    @load_balancer ||= LoadBalancer[frame.fetch("load_balancer_id")]
  end

  def inhost_name
    vm.inhost_name
  end

  def run_nft_rules(rules)
    if provider_backed_vm?
      vm.sshable.cmd("sudo nft --file -", stdin: rules)
    else
      vm.vm_host.sshable.cmd("sudo ip netns exec :inhost_name nft --file -", inhost_name:, stdin: rules)
    end
  end

  def run_linode_script(script)
    vm.sshable.cmd("sudo bash -s", stdin: script)
  end

  def before_run
    super
    pop "VM is destroyed" unless vm
  end

  label def update_load_balancer
    vm.load_balancer_vm_ports.select { |lvp| lvp.state == "detaching" }.sort_by(&:stack).each do |load_balancer_vm_port|
      load_balancer.remove_vm_port(load_balancer_vm_port)
    end

    # If there is literally no up resource to balance to, keep provider-backed
    # empty load balancers reachable with a small holding page.
    if load_balancer.active_vm_ports.count == 0
      if linode_waiting_page_enabled? && !force_remove_waiting_page?
        setup_linode_waiting_page
        run_nft_rules(generate_flush_nat_rules)
        pop "load balancer waiting page is active"
      end

      hop_remove_load_balancer
    end

    remove_linode_waiting_page if provider_backed_vm?
    run_nft_rules(generate_lb_based_nat_rules)
    pop "load balancer is updated"
  end

  label def remove_load_balancer
    if provider_backed_vm?
      remove_linode_waiting_page if force_remove_waiting_page? || !linode_waiting_page_enabled?
      run_nft_rules(generate_flush_nat_rules)
    else
      run_nft_rules(generate_nat_rules(vm.ip4_string, vm.private_ipv4.to_s))
    end

    pop "load balancer is removed"
  end

  def load_balancer_ports_to_work_on
    @load_balancer_ports_to_work_on ||= load_balancer.active_vm_ports { |ds| ds.eager_graph(:load_balancer_port).eager(load_balancer_vm: {vm: :nics}).order(:src_port) }
  end

  def generate_lb_based_nat_rules
    public_ipv4 = vm.ip4_string
    public_ipv6 = vm.ip6_string
    private_ipv4 = vm.private_ipv4
    private_ipv6 = vm.private_ipv6
    neighbor_ips_v4_set, neighbor_ips_v6_set = generate_lb_ip_set_definition(load_balancer_ports_to_work_on.reject { it.load_balancer_vm.vm_id == vm.id })

    balance_mode_ip4, balance_mode_ip6 = if load_balancer.algorithm == "round_robin"
      ["numgen inc", "numgen inc"]
    elsif load_balancer.algorithm == "hash_based"
      ["jhash ip saddr . tcp sport . ip daddr . tcp dport", "jhash ip6 saddr . tcp sport . ip6 daddr . tcp dport"]
    else
      fail ArgumentError, "Unsupported load balancer algorithm: #{load_balancer.algorithm}"
    end

    ipv4_prerouting = if load_balancer.ipv4_enabled?
      load_balancer_ports_to_work_on.select { |vm_port| vm_port.stack == "ipv4" }.uniq(&:load_balancer_port_id).map do |vm_port|
        port = vm_port.load_balancer_port
        ipv4_map_def = generate_lb_map_defs_ipv4(port)
        modulo = ipv4_map_def.count
        local_private_rule = unless provider_backed_vm?
          "ip daddr #{private_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{private_ipv4}:#{port.dst_port}"
        end
        <<-IPV4_PREROUTING
ip daddr #{public_ipv4} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip daddr #{public_ipv4} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip4} mod #{modulo} map { #{ipv4_map_def.join(", ")} }
#{local_private_rule}
        IPV4_PREROUTING
      end.join("\n")
    end

    ipv6_prerouting = if load_balancer.ipv6_enabled?
      load_balancer_ports_to_work_on.select { |vm_port| vm_port.stack == "ipv6" }.uniq(&:load_balancer_port_id).map do |vm_port|
        port = vm_port.load_balancer_port
        ipv6_map_def = generate_lb_map_defs_ipv6(port)
        modulo = ipv6_map_def.count
        local_private_rule = unless provider_backed_vm?
          "ip6 daddr #{private_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to [#{public_ipv6}]:#{port.dst_port}"
        end
        <<-IPV6_PREROUTING
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip6} mod #{modulo} map { #{ipv6_map_def.join(", ")} }
#{local_private_rule}
        IPV6_PREROUTING
      end.join("\n")
    end

    ipv4_output = if provider_backed_vm? && load_balancer.ipv4_enabled?
      load_balancer_ports_to_work_on
        .select { |vm_port| vm_port.stack == "ipv4" && vm_port.load_balancer_vm.vm_id == vm.id }
        .uniq(&:load_balancer_port_id)
        .map do |vm_port|
          port = vm_port.load_balancer_port
          "ip daddr #{public_ipv4} tcp dport #{port.src_port} redirect to :#{port.dst_port}"
        end.join("\n")
    end

    ipv6_output = if provider_backed_vm? && load_balancer.ipv6_enabled?
      load_balancer_ports_to_work_on
        .select { |vm_port| vm_port.stack == "ipv6" && vm_port.load_balancer_vm.vm_id == vm.id }
        .uniq(&:load_balancer_port_id)
        .map do |vm_port|
          port = vm_port.load_balancer_port
          "ip6 daddr #{public_ipv6} tcp dport #{port.src_port} redirect to :#{port.dst_port}"
        end.join("\n")
    end

    sorted_ports = load_balancer.ports.sort_by { |port| port.src_port }
    ipv4_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv4_enabled?
        snat_address = provider_backed_vm? ? public_ipv4 : private_ipv4
        "ip daddr @neighbor_ips_v4 tcp dport #{port.src_port} ct state established,related,new counter snat to #{snat_address}"
      end
    end.join("\n")

    ipv6_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv6_enabled?
        snat_address = provider_backed_vm? ? public_ipv6 : private_ipv6
        "ip6 daddr @neighbor_ips_v6 tcp dport #{port.src_port} ct state established,related,new counter snat to #{snat_address}"
      end
    end.join("\n")

    basic_prerouting_rule = unless provider_backed_vm?
      "# Basic NAT for public IPv4 to private IPv4\n    ip daddr #{public_ipv4} dnat to #{private_ipv4}"
    end
    basic_postrouting_rule = unless provider_backed_vm?
      <<~RULE.chomp
        # Basic NAT for private IPv4 to public IPv4
            ip saddr #{private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{public_ipv4}
            ip saddr #{private_ipv4} ip daddr #{private_ipv4} snat to #{public_ipv4}
      RULE
    end

    <<TEMPLATE
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
#{neighbor_ips_v4_set}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
#{neighbor_ips_v6_set}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
#{ipv4_prerouting}
#{ipv6_prerouting}

    #{basic_prerouting_rule}
  }

  chain output {
    type nat hook output priority dstnat; policy accept;
#{ipv4_output}
#{ipv6_output}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
#{ipv4_postrouting_rule}
#{ipv6_postrouting_rule}

    #{basic_postrouting_rule}
  }
}
TEMPLATE
  end

  def generate_lb_ip_set_definition(neighbor_vm_ports)
    return ["", ""] if neighbor_vm_ports.empty?
    ipv4_ips = neighbor_vm_ports.select { it.stack == "ipv4" }.map { backend_ipv4(it.vm) }.uniq.join(", ")
    ipv6_ips = neighbor_vm_ports.select { it.stack == "ipv6" }.map { backend_ipv6(it.vm) }.uniq.join(", ")
    [ipv4_ips.empty? ? "" : "elements = {#{ipv4_ips}}",
      ipv6_ips.empty? ? "" : "elements = {#{ipv6_ips}}"]
  end

  def generate_lb_map_defs(current_port, stack)
    items = load_balancer.active_vm_ports
      .select { |vm_port| vm_port.load_balancer_port.dst_port == current_port.dst_port && vm_port.stack == stack }
      .map do |vm_port|
        address = yield vm_port
        port = (vm_port.load_balancer_vm.vm_id == vm.id) ? vm_port.load_balancer_port.dst_port : vm_port.load_balancer_port.src_port
        [address.to_s, port.to_i]
      end

    items.sort!.map!.with_index do |(address, port), index|
      "#{index} : #{address} . #{port}"
    end
  end

  def generate_lb_map_defs_ipv4(current_port)
    generate_lb_map_defs(current_port, "ipv4") do |vm_port|
      backend_ipv4(vm_port.load_balancer_vm.vm)
    end
  end

  def generate_lb_map_defs_ipv6(current_port)
    generate_lb_map_defs(current_port, "ipv6") do |vm_port|
      backend_ipv6(vm_port.load_balancer_vm.vm)
    end
  end

  def backend_ipv4(backend_vm)
    provider_backed_vm? ? backend_vm.ip4 : backend_vm.private_ipv4
  end

  def backend_ipv6(backend_vm)
    provider_backed_vm? ? backend_vm.ip6 : backend_vm.private_ipv6
  end

  def generate_nat_rules(current_public_ipv4, current_private_ipv4)
    <<NAT
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr #{current_public_ipv4} dnat to #{current_private_ipv4}
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr #{current_private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{current_public_ipv4}
    ip saddr #{current_private_ipv4} ip daddr #{current_private_ipv4} snat to #{current_public_ipv4}
  }
}
NAT
  end

  def generate_flush_nat_rules
    <<NAT
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
NAT
  end

  def linode_waiting_page_enabled?
    provider_backed_vm? && load_balancer.ports_dataset.empty?
  end

  def force_remove_waiting_page?
    frame["remove_waiting_page"] == true
  end

  def provider_backed_vm?
    vm.location.linode? || vm.location.azure?
  end

  def setup_linode_waiting_page
    run_linode_script(<<~SH)
      set -euo pipefail

      if ! command -v ruby >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y ruby
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y ruby
        elif command -v yum >/dev/null 2>&1; then
          yum install -y ruby
        fi
      fi

      install -d -m 0755 /etc/layerrail/load-balancer
      cat >/usr/local/bin/layerrail-lb-waiting-page.rb <<'RUBY'
      #{linode_waiting_page_ruby_script}
      RUBY
      chmod 0755 /usr/local/bin/layerrail-lb-waiting-page.rb

      cat >/etc/systemd/system/layerrail-lb-waiting-page.service <<'SYSTEMD'
      #{linode_waiting_page_systemd_unit}
      SYSTEMD

      systemctl daemon-reload
      systemctl enable layerrail-lb-waiting-page >/dev/null
      systemctl restart layerrail-lb-waiting-page
    SH
  end

  def remove_linode_waiting_page
    run_linode_script(<<~SH)
      set -euo pipefail
      systemctl disable --now layerrail-lb-waiting-page >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/layerrail-lb-waiting-page.service
      rm -f /usr/local/bin/layerrail-lb-waiting-page.rb
      systemctl daemon-reload || true
    SH
  end

  def linode_waiting_page_systemd_unit
    <<~SYSTEMD
      [Unit]
      Description=LayerRail load balancer waiting page
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      Environment=LAYERRAIL_LB_HOSTNAME=#{load_balancer.hostname}
      ExecStart=/usr/bin/env ruby /usr/local/bin/layerrail-lb-waiting-page.rb
      Restart=always
      RestartSec=3

      [Install]
      WantedBy=multi-user.target
    SYSTEMD
  end

  def linode_waiting_page_ruby_script
    <<~'RUBY'
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      require "openssl"
      require "socket"
      require "cgi"

      HOSTNAME = ENV.fetch("LAYERRAIL_LB_HOSTNAME", "layerrail.com")
      DISPLAY_HOSTNAME = CGI.escapeHTML(HOSTNAME)
      CERT_PATH = "/etc/layerrail/load-balancer/cert.pem"
      KEY_PATH = "/etc/layerrail/load-balancer/key.pem"

      PAGE = <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>LayerRail endpoint is live</title>
          <style>
            :root {
              color-scheme: dark;
              --bg: #08070c;
              --surface: #111017;
              --surface-2: #16131f;
              --text: #fefdfe;
              --muted: #bcb9c1;
              --soft: #ebe9f1;
              --line: rgba(209, 200, 231, 0.16);
              --accent: #8b67f2;
              --accent-soft: #d1c8e7;
              --deep: #5a3a38;
              --ok: #86efac;
            }

            * { box-sizing: border-box; }

            body {
              margin: 0;
              min-height: 100vh;
              background:
                radial-gradient(circle at 18% 8%, rgba(139, 103, 242, 0.22), transparent 30rem),
                radial-gradient(circle at 80% 16%, rgba(209, 200, 231, 0.08), transparent 28rem),
                linear-gradient(180deg, #0b0911 0%, var(--bg) 58%, #09080d 100%);
              color: var(--text);
              font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              overflow-x: hidden;
            }

            body::before {
              content: "";
              position: fixed;
              inset: 0;
              pointer-events: none;
              background-image:
                linear-gradient(rgba(255, 255, 255, 0.035) 1px, transparent 1px),
                linear-gradient(90deg, rgba(255, 255, 255, 0.035) 1px, transparent 1px);
              background-size: 64px 64px;
              mask-image: linear-gradient(to bottom, rgba(0,0,0,0.62), transparent 68%);
            }

            .shell {
              width: min(1180px, calc(100vw - 48px));
              margin: 0 auto;
              min-height: 100vh;
              display: flex;
              flex-direction: column;
              position: relative;
              z-index: 1;
            }

            header {
              height: 84px;
              display: flex;
              align-items: center;
              justify-content: space-between;
              border-bottom: 1px solid var(--line);
            }

            .brand {
              display: flex;
              align-items: center;
              gap: 12px;
              color: var(--text);
              font-weight: 700;
              letter-spacing: 0;
            }

            .brand-mark {
              width: 34px;
              height: 34px;
              display: grid;
              place-items: center;
              border: 1px solid rgba(139, 103, 242, 0.42);
              border-radius: 8px;
              background: linear-gradient(145deg, rgba(139, 103, 242, 0.95), rgba(209, 200, 231, 0.5));
              box-shadow: 0 0 32px rgba(139, 103, 242, 0.28);
              font-size: 0.82rem;
              font-weight: 800;
            }

            .status-pill {
              display: inline-flex;
              align-items: center;
              gap: 8px;
              padding: 8px 12px;
              border: 1px solid rgba(134, 239, 172, 0.22);
              border-radius: 999px;
              background: rgba(134, 239, 172, 0.06);
              color: var(--soft);
              font-size: 0.86rem;
              font-weight: 600;
            }

            .status-dot {
              width: 8px;
              height: 8px;
              border-radius: 999px;
              background: var(--ok);
              box-shadow: 0 0 18px rgba(134, 239, 172, 0.85);
            }

            main {
              flex: 1;
              display: grid;
              grid-template-columns: minmax(0, 1.05fr) minmax(360px, 0.95fr);
              gap: 64px;
              align-items: center;
              padding: 72px 0 84px;
            }

            .eyebrow {
              display: inline-flex;
              align-items: center;
              gap: 10px;
              margin-bottom: 24px;
              padding: 8px 12px;
              border: 1px solid var(--line);
              border-radius: 999px;
              color: var(--accent-soft);
              background: rgba(255, 255, 255, 0.035);
              font-size: 0.84rem;
              font-weight: 700;
            }

            h1 {
              margin: 0;
              max-width: 760px;
              font-size: clamp(3rem, 8vw, 6.8rem);
              line-height: 0.94;
              letter-spacing: 0;
            }

            .lead {
              margin: 26px 0 0;
              max-width: 650px;
              color: var(--muted);
              font-size: clamp(1rem, 2vw, 1.18rem);
              line-height: 1.75;
            }

            .endpoint {
              width: min(100%, 620px);
              margin-top: 34px;
              padding: 16px 18px;
              border: 1px solid var(--line);
              border-radius: 10px;
              background: rgba(255, 255, 255, 0.04);
              box-shadow: inset 0 1px 0 rgba(255,255,255,0.05);
            }

            .endpoint span {
              display: block;
              margin-bottom: 8px;
              color: var(--muted);
              font-size: 0.78rem;
              font-weight: 700;
              letter-spacing: 0.08em;
              text-transform: uppercase;
            }

            code {
              color: var(--text);
              font: 0.95rem ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
              word-break: break-word;
            }

            .panel {
              position: relative;
              min-height: 470px;
              padding: 28px;
              border: 1px solid var(--line);
              border-radius: 18px;
              background:
                linear-gradient(180deg, rgba(255,255,255,0.06), rgba(255,255,255,0.025)),
                var(--surface);
              box-shadow: 0 28px 90px rgba(0, 0, 0, 0.34);
              overflow: hidden;
            }

            .panel::before {
              content: "";
              position: absolute;
              inset: -1px;
              background:
                radial-gradient(circle at 70% 0%, rgba(139, 103, 242, 0.28), transparent 16rem),
                linear-gradient(135deg, transparent 0 42%, rgba(139, 103, 242, 0.14) 42% 43%, transparent 43% 100%);
              pointer-events: none;
            }

            .panel-content {
              position: relative;
              z-index: 1;
            }

            .panel-heading {
              display: flex;
              justify-content: space-between;
              align-items: center;
              gap: 18px;
              margin-bottom: 42px;
            }

            .panel-title {
              margin: 0;
              color: var(--soft);
              font-size: 0.95rem;
              font-weight: 800;
            }

            .panel-label {
              color: var(--muted);
              font-size: 0.82rem;
            }

            .flow {
              display: grid;
              gap: 18px;
            }

            .flow-row {
              display: grid;
              grid-template-columns: 90px 1fr;
              gap: 18px;
              align-items: center;
            }

            .node {
              min-height: 76px;
              padding: 15px;
              border: 1px solid var(--line);
              border-radius: 12px;
              background: rgba(8, 7, 12, 0.58);
            }

            .node strong {
              display: block;
              color: var(--text);
              font-size: 0.94rem;
            }

            .node span {
              display: block;
              margin-top: 6px;
              color: var(--muted);
              font-size: 0.86rem;
              line-height: 1.45;
            }

            .rail {
              height: 2px;
              background: linear-gradient(90deg, rgba(139,103,242,0), rgba(139,103,242,0.88), rgba(209,200,231,0.18));
              position: relative;
            }

            .rail::after {
              content: "";
              position: absolute;
              right: -5px;
              top: 50%;
              width: 10px;
              height: 10px;
              border-top: 2px solid rgba(209,200,231,0.8);
              border-right: 2px solid rgba(209,200,231,0.8);
              transform: translateY(-50%) rotate(45deg);
            }

            .metrics {
              display: grid;
              grid-template-columns: repeat(3, 1fr);
              gap: 10px;
              margin-top: 42px;
            }

            .metric {
              padding: 14px;
              border: 1px solid var(--line);
              border-radius: 12px;
              background: rgba(255, 255, 255, 0.035);
            }

            .metric b {
              display: block;
              color: var(--text);
              font-size: 0.9rem;
            }

            .metric span {
              display: block;
              margin-top: 6px;
              color: var(--muted);
              font-size: 0.78rem;
              line-height: 1.45;
            }

            footer {
              display: flex;
              justify-content: space-between;
              gap: 18px;
              padding: 22px 0 28px;
              border-top: 1px solid var(--line);
              color: rgba(188, 185, 193, 0.78);
              font-size: 0.86rem;
            }

            footer a {
              color: var(--accent-soft);
              text-decoration: none;
            }

            @media (max-width: 900px) {
              .shell {
                width: min(100vw - 28px, 720px);
              }

              header {
                height: 72px;
              }

              main {
                grid-template-columns: 1fr;
                gap: 34px;
                padding: 46px 0 56px;
              }

              .panel {
                min-height: auto;
              }
            }

            @media (max-width: 560px) {
              .status-pill {
                display: none;
              }

              h1 {
                font-size: clamp(2.65rem, 16vw, 4.2rem);
              }

              .panel,
              .endpoint {
                border-radius: 14px;
              }

              .flow-row {
                grid-template-columns: 1fr;
                gap: 10px;
              }

              .rail {
                width: 2px;
                height: 34px;
                margin-left: 18px;
                background: linear-gradient(180deg, rgba(139,103,242,0.88), rgba(209,200,231,0.18));
              }

              .rail::after {
                right: auto;
                left: 50%;
                top: auto;
                bottom: -5px;
                transform: translateX(-50%) rotate(135deg);
              }

              .metrics {
                grid-template-columns: 1fr;
              }

              footer {
                flex-direction: column;
              }
            }
          </style>
        </head>
        <body>
          <div class="shell">
            <header>
              <div class="brand">
                <div class="brand-mark">LR</div>
                <span>LayerRail</span>
              </div>
              <div class="status-pill"><span class="status-dot"></span> Load balancer online</div>
            </header>

            <main>
              <section>
                <div class="eyebrow">Service endpoint</div>
                <h1>Waiting for your app.</h1>
                <p class="lead">Traffic is reaching this LayerRail load balancer. Attach a backend service, Kubernetes route, or deployment target to start serving requests from this hostname.</p>
                <div class="endpoint">
                  <span>Hostname</span>
                  <code>#{DISPLAY_HOSTNAME}</code>
                </div>
              </section>

              <section class="panel" aria-label="Endpoint status">
                <div class="panel-content">
                  <div class="panel-heading">
                    <p class="panel-title">Request path</p>
                    <span class="panel-label">Ready for upstreams</span>
                  </div>

                  <div class="flow">
                    <div class="flow-row">
                      <div class="rail"></div>
                      <div class="node">
                        <strong>DNS route</strong>
                        <span>The hostname resolves to LayerRail edge infrastructure.</span>
                      </div>
                    </div>
                    <div class="flow-row">
                      <div class="rail"></div>
                      <div class="node">
                        <strong>Load balancer</strong>
                        <span>The endpoint is online and accepting incoming traffic.</span>
                      </div>
                    </div>
                    <div class="flow-row">
                      <div class="rail"></div>
                      <div class="node">
                        <strong>Application service</strong>
                        <span>No upstream response is attached yet. Deploy or connect your service to take over this page.</span>
                      </div>
                    </div>
                  </div>

                  <div class="metrics">
                    <div class="metric"><b>HTTP</b><span>Port 80 ready</span></div>
                    <div class="metric"><b>HTTPS</b><span>TLS when configured</span></div>
                    <div class="metric"><b>Region</b><span>LayerRail network</span></div>
                  </div>
                </div>
              </section>
            </main>

            <footer>
              <span>LayerRail managed endpoint</span>
              <a href="https://console.layerrail.com">console.layerrail.com</a>
            </footer>
          </div>
        </body>
        </html>
      HTML

      RESPONSE_HEADERS = [
        "HTTP/1.1 200 OK",
        "Content-Type: text/html; charset=utf-8",
        "Content-Length: #{PAGE.bytesize}",
        "Cache-Control: no-store",
        "Connection: close",
        "\r\n"
      ].join("\r\n")

      def handle(client)
        client.gets
        while (line = client.gets)
          break if line == "\r\n"
        end
        client.write(RESPONSE_HEADERS)
        client.write(PAGE)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        client&.close
      end

      def serve_tcp(host, port)
        server = TCPServer.new(host, port)
        loop { Thread.new(server.accept) { |client| handle(client) } }
      rescue SystemCallError => ex
        warn "LayerRail waiting page could not bind #{host}:#{port}: #{ex.message}"
      end

      def serve_tls(host, port)
        return unless File.exist?(CERT_PATH) && File.exist?(KEY_PATH)

        context = OpenSSL::SSL::SSLContext.new
        context.cert = OpenSSL::X509::Certificate.new(File.read(CERT_PATH))
        context.key = OpenSSL::PKey.read(File.read(KEY_PATH))
        server = OpenSSL::SSL::SSLServer.new(TCPServer.new(host, port), context)
        loop { Thread.new(server.accept) { |client| handle(client) } }
      rescue SystemCallError, OpenSSL::SSL::SSLError => ex
        warn "LayerRail waiting page could not bind TLS #{host}:#{port}: #{ex.message}"
      end

      threads = [
        Thread.new { serve_tcp("0.0.0.0", 80) },
        Thread.new { serve_tcp("::", 80) },
        Thread.new { serve_tls("0.0.0.0", 443) },
        Thread.new { serve_tls("::", 443) }
      ]

      threads.each(&:join)
    RUBY
  end
end
