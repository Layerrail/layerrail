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
    Nic.new_with_id(private_subnet_id: private_subnet.id, vm_id: vm.id,
      name: "azure-nic", private_ipv4: "10.0.0.4/32", private_ipv6: "fd10:9b0b:6b4b:8fbb::4/128", state: "active").save_changes
    Strand.create_with_id(private_subnet, prog: "Vnet::Azure::SubnetNexus", label: "wait")
    Strand.create_with_id(vm.nics.first, prog: "Vnet::Azure::NicNexus", label: "wait")
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

  describe "#start" do
    before do
      vm.update(display_state: "creating")
      vm.semaphores_dataset.destroy
      strand.update(label: "start")
      private_subnet.strand.update(label: "wait")
      vm.nics.first.strand.update(label: "wait")
      vm.azure_instance&.destroy
    end

    it "passes a plain private IPv4 address to Azure NIC creation" do
      allow(client).to receive(:create_resource_group)
      allow(client).to receive(:create_network_security_group).and_return({"id" => "nsg-id"})
      allow(client).to receive(:create_virtual_network).and_return({"properties" => {"subnets" => [{"id" => "subnet-id"}]}})
      allow(client).to receive(:create_public_ip).and_return({"id" => "public-ip-id"})
      allow(client).to receive(:create_virtual_machine)

      expect(client).to receive(:create_network_interface).with(hash_including(private_ip: "10.0.0.4")).and_return({"id" => "nic-id"})

      expect { nx.start }.to hop("wait_instance_created")
    end

    it "records Azure data disks by stable LUN device path" do
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1)
      allow(client).to receive(:create_resource_group)
      allow(client).to receive(:create_network_security_group).and_return({"id" => "nsg-id"})
      allow(client).to receive(:create_virtual_network).and_return({"properties" => {"subnets" => [{"id" => "subnet-id"}]}})
      allow(client).to receive(:create_public_ip).and_return({"id" => "public-ip-id"})
      allow(client).to receive(:create_network_interface).and_return({"id" => "nic-id"})
      allow(client).to receive(:create_virtual_machine)

      expect { nx.start }.to hop("wait_instance_created")

      volume = vm.reload.vm_storage_volumes.find { |vol| !vol.boot }
      expect(volume.azure_storage_volume.device_path).to eq("/dev/disk/azure/data/by-lun/0")
    end

    it "retries transient Azure subnet convergence errors without failing the VM" do
      allow(client).to receive(:create_resource_group)
      allow(client).to receive(:create_network_security_group).and_raise(AzureAPIError.new(429, "ReferencedResourceNotProvisioned: subnet is in Updating state"))

      expect { nx.start }.to nap(30)
      expect(vm.reload.display_state).to eq("creating")
      expect(Page.where(Sequel.like(:tag, "AzureCreateFailed%")).count).to eq(0)
    end
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
