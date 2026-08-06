# frozen_string_literal: true

require "open3"
require "tempfile"

RSpec.describe "Kubernetes containerd configuration" do
  let(:source_path) { File.expand_path("../../../prog/kubernetes/provision_kubernetes_node.rb", __dir__) }

  def containerd_config
    source = File.binread(source_path).gsub("\r\n", "\n")
    source.match(/cat > "\$containerd_config" <<'EOF'\n(?<config>.*?)\nEOF/m)[:config] + "\n"
  end

  def parse_with_containerd(runtime)
    Tempfile.create("containerd-config") do |file|
      file.binmode
      file.write(containerd_config)
      file.close
      Open3.capture3(runtime, "--config", file.path, "config", "dump")
    end
  end

  it "uses the stable version 2 CRI schema and systemd cgroups" do
    expect(containerd_config).to include("version = 2")
    expect(containerd_config).to include('[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]')
    expect(containerd_config).to include("SystemdCgroup = true")
    expect(containerd_config).not_to include("SystemdCgroup = false")
  end

  it "is accepted by an installed containerd runtime" do
    runtime = ENV.fetch("CONTAINERD_BIN", "containerd")
    skip "#{runtime} is not installed" unless system(runtime, "--version", out: File::NULL, err: File::NULL)

    output, error, status = parse_with_containerd(runtime)

    expect(status).to be_success, error
    expect(output).to include("SystemdCgroup = true")
  end
end
