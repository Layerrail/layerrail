# frozen_string_literal: true

RSpec.describe Prog::Vm::Azure::Nexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "azure-vm-project") }
  let(:location) {
    Location.create(name: "azure-eastus", provider: "azure", project_id: project.id,
      display_name: "azure-eastus", ui_name: "East US", visible: true)
  }
  let(:private_subnet) {
    PrivateSubnet.create(project_id: project.id, name: "azure-ps", location_id: location.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/24")
  }
  let(:vm) {
    create_vm(project_id: project.id, location_id: location.id, display_state: "running",
      family: "nanode", vcpus: 2, memory_gib: 4)
  }
  let(:strand) { Strand.create_with_id(vm, prog: "Vm::Azure::Nexus", label: "destroy") }
  let(:client) { instance_double(AzureClient) }

  before do
    Nic.create_with_id(vm.id, private_subnet_id: private_subnet.id, vm_id: vm.id,
      name: "azure-nic", private_ipv4: "10.0.0.4/32", private_ipv6: "fd10:9b0b:6b4b:8fbb::4/128", state: "active")
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 80, disk_index: 0)
    AzureInstance.create_with_id(vm,
      resource_group: "rg-test",
      region: "eastus",
      vm_name: "vm-test",
      vm_size: "Standard_D2lds_v7",
      image: {},
      vnet_name: "vnet-test",
      subnet_name: "subnet-test",
      nsg_name: "nsg-test",
      nic_name: "nic-test",
      public_ip_name: "pip-test",
      os_disk_name: "osdisk-test")
    vm.incr_destroy
    allow(AzureClient).to receive(:new).and_return(client)
  end

  it "retries Azure cleanup while dependent resources are still attached" do
    allow(client).to receive(:delete_virtual_machine)
    allow(client).to receive(:delete_disk).and_raise(AzureAPIError.new(409, "disk is attached to a VM"))

    expect { nx.destroy }.to nap(30)
    expect(vm.reload.display_state).to eq("deleting")
    expect(vm.azure_instance).not_to be_nil
  end

  it "cleans local records after Azure accepts leftover resource deletion" do
    allow(client).to receive(:delete_virtual_machine)
    allow(client).to receive(:delete_disk)
    allow(client).to receive(:delete_network_interface)
    allow(client).to receive(:delete_public_ip)

    expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    expect(Vm[vm.id]).to be_nil
  end
end
