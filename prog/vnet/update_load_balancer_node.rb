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
    if vm.location.linode?
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

    # If there is literally no up resource to balance to, keep Linode-backed
    # empty load balancers reachable with a small holding page.
    if load_balancer.active_vm_ports.count == 0
      if linode_waiting_page_enabled? && !force_remove_waiting_page?
        setup_linode_waiting_page
        run_nft_rules(generate_flush_nat_rules)
        pop "load balancer waiting page is active"
      end

      hop_remove_load_balancer
    end

    remove_linode_waiting_page if vm.location.linode?
    run_nft_rules(generate_lb_based_nat_rules)
    pop "load balancer is updated"
  end

  label def remove_load_balancer
    if vm.location.linode?
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
        local_private_rule = unless vm.location.linode?
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
        local_private_rule = unless vm.location.linode?
          "ip6 daddr #{private_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to [#{public_ipv6}]:#{port.dst_port}"
        end
        <<-IPV6_PREROUTING
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} meta mark set 0x00B1C100D
ip6 daddr #{public_ipv6} tcp dport #{port.src_port} ct state established,related,new counter dnat to #{balance_mode_ip6} mod #{modulo} map { #{ipv6_map_def.join(", ")} }
#{local_private_rule}
        IPV6_PREROUTING
      end.join("\n")
    end

    ipv4_output = if vm.location.linode? && load_balancer.ipv4_enabled?
      load_balancer_ports_to_work_on
        .select { |vm_port| vm_port.stack == "ipv4" && vm_port.load_balancer_vm.vm_id == vm.id }
        .uniq(&:load_balancer_port_id)
        .map do |vm_port|
          port = vm_port.load_balancer_port
          "ip daddr #{public_ipv4} tcp dport #{port.src_port} redirect to :#{port.dst_port}"
        end.join("\n")
    end

    ipv6_output = if vm.location.linode? && load_balancer.ipv6_enabled?
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
        snat_address = vm.location.linode? ? public_ipv4 : private_ipv4
        "ip daddr @neighbor_ips_v4 tcp dport #{port.src_port} ct state established,related,new counter snat to #{snat_address}"
      end
    end.join("\n")

    ipv6_postrouting_rule = sorted_ports.map do |port|
      if load_balancer.ipv6_enabled?
        snat_address = vm.location.linode? ? public_ipv6 : private_ipv6
        "ip6 daddr @neighbor_ips_v6 tcp dport #{port.src_port} ct state established,related,new counter snat to #{snat_address}"
      end
    end.join("\n")

    basic_prerouting_rule = unless vm.location.linode?
      "# Basic NAT for public IPv4 to private IPv4\n    ip daddr #{public_ipv4} dnat to #{private_ipv4}"
    end
    basic_postrouting_rule = unless vm.location.linode?
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
    vm.location.linode? ? backend_vm.ip4 : backend_vm.private_ipv4
  end

  def backend_ipv6(backend_vm)
    vm.location.linode? ? backend_vm.ip6 : backend_vm.private_ipv6
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
    vm.location.linode? && load_balancer.ports_dataset.empty?
  end

  def force_remove_waiting_page?
    frame["remove_waiting_page"] == true
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

      HOSTNAME = ENV.fetch("LAYERRAIL_LB_HOSTNAME", "layerrail.com")
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
              --bg: #0f0d14;
              --panel: #17131f;
              --text: #fefdfe;
              --muted: #bcb9c1;
              --line: #2f2838;
              --accent: #8b67f2;
            }

            * { box-sizing: border-box; }

            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: radial-gradient(circle at 50% 0%, #24183d 0, var(--bg) 42%);
              color: var(--text);
              font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }

            main {
              width: min(92vw, 680px);
              padding: 36px;
              border: 1px solid var(--line);
              border-radius: 8px;
              background: color-mix(in srgb, var(--panel) 92%, transparent);
              box-shadow: 0 24px 80px rgba(0, 0, 0, 0.28);
            }

            .mark {
              width: 44px;
              height: 44px;
              display: grid;
              place-items: center;
              border-radius: 8px;
              background: var(--accent);
              color: white;
              font-weight: 800;
              margin-bottom: 24px;
            }

            h1 {
              margin: 0;
              font-size: clamp(2rem, 5vw, 4.6rem);
              line-height: 0.95;
              letter-spacing: 0;
            }

            p {
              margin: 18px 0 0;
              max-width: 56ch;
              color: var(--muted);
              font-size: 1.05rem;
              line-height: 1.6;
            }

            code {
              display: inline-block;
              margin-top: 22px;
              padding: 8px 10px;
              border: 1px solid var(--line);
              border-radius: 6px;
              color: var(--text);
              background: rgba(255, 255, 255, 0.04);
              font: 0.92rem ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
              word-break: break-word;
            }
          </style>
        </head>
        <body>
          <main>
            <div class="mark">LR</div>
            <h1>Endpoint ready</h1>
            <p>This LayerRail load balancer is live. Attach a service or deployment to start serving application traffic.</p>
            <code>#{HOSTNAME}</code>
          </main>
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
