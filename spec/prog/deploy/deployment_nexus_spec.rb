# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Prog::Deploy::DeploymentNexus do
  subject(:nx) { described_class.new(deployment.strand) }

  let(:project) { Project.create(name: "project-1") }
  let(:dns_project) { Project.create(name: "deploy-dns") }
  let(:installation) { GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: project.id) }
  let(:location) { Location.where(visible: true).order(:ui_name).first }
  let(:app) do
    DeployApp.create(
      project_id: project.id,
      installation_id: installation.id,
      location_id: location.id,
      name: "web",
      repository: "test-user/web",
      branch: "main",
      install_command: "npm ci",
      build_command: "npm run build",
      start_command: "npm start",
      app_port: 3000,
      vm_size: DeployApp.vm_size_options.first.first,
      framework: "node",
      status: "idle",
    )
  end
  let(:deployment) { described_class.assemble(app) }

  before do
    allow(Config).to receive(:deploy_service_hostname).and_return("apps.layerrail.test")
    allow(Config).to receive(:deploy_service_project_id).and_return(dns_project.id)
  end

  it "writes a temporary app page before the slow build starts" do
    script = nx.send(:remote_deploy_script, "github-token")

    expect(script).to include("write_deploy_page \"Deployment in progress\"")
    expect(script).to include("write_deploy_page \"Deployment failed\"")
    expect(script).to include("root /var/www/layerrail-deploy;")
  end

  it "creates the public DNS record for the app VM" do
    vm = create_vm(project_id: project.id, ip4_enabled: true)
    add_ipv4_to_vm(vm, "203.0.113.10")
    app.update(vm_id: vm.id, hostname: "web-test.apps.layerrail.test")

    nx.send(:configure_dns_record)

    zone = DnsZone.first(project_id: dns_project.id, name: "apps.layerrail.test")
    expect(zone.records_dataset.where(name: "web-test.apps.layerrail.test.", type: "A", data: "203.0.113.10").count).to eq(1)
  end

  it "updates DNS before starting the remote build service" do
    sshable = instance_double(Sshable)
    vm = instance_double(Vm, sshable:)

    expect(nx).to receive(:configure_dns_record).ordered
    expect(sshable).to receive(:cmd).ordered.with("sudo bash -s", hash_including(log: false, timeout: 30)).and_return("")
    allow(nx).to receive(:vm).and_return(vm)
    allow(nx).to receive(:github_access_token).and_return("github-token")

    expect { nx.start_remote_build }.to hop("poll_remote_build")
    expect(deployment.reload.status).to eq("building")
    expect(app.reload.status).to eq("deploying")
  end
end
