# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Option do
  describe "#VmSize options" do
    it "no burstable cpu allowed for dedicated VMs" do
      expect(Option::VmSizes.map {
        (it.name.include?("burstable-") || it.name.include?("nanode-")) == (it.cpu_burst_percent_limit > 0)
      }.all?(true)).to be true
    end

    it "no odd number of vcpus allowed, except for 1" do
      expect(Option::VmSizes.all? { it.vcpus == 1 || it.vcpus.even? }).to be true
    end
  end

  describe "#VmFamily options" do
    it "families include burstables" do
      expect(described_class.families.map(&:name)).to include("burstable")
    end
  end

  describe ".linode_plan" do
    it "maps the exposed Nanode starter size to the real Linode Nanode plan" do
      expect(described_class.linode_plan("nanode", 1).id).to eq("g6-nanode-1")
    end

    it "maps the expanded Nanode starter sizes to the correct Linode shared plans" do
      expect(described_class.linode_plan("nanode", 1, size_name: "nanode-2").id).to eq("g6-standard-1")
      expect(described_class.linode_plan("nanode", 2, size_name: "nanode-4").id).to eq("g6-standard-2")
      expect(described_class.linode_plan("nanode", 4, size_name: "nanode-8").id).to eq("g6-standard-4")
    end

    it "maps the exposed GPU size to the real Linode RTX 4000 Ada small plan" do
      expect(described_class.linode_plan("standard", 4, gpu_count: 1, gpu_device: described_class::LINODE_GPU_DEVICE).id).to eq("g2-gpu-rtx4000a1-s")
      expect {
        described_class.linode_plan("standard", 8, gpu_count: 1, gpu_device: described_class::LINODE_GPU_DEVICE)
      }.to raise_error(Validation::ValidationFailed)
    end
  end

  describe ".linode_gpu_location?" do
    it "only exposes the chosen Linode GPU regions" do
      expect(described_class.linode_gpu_location?("linode-de-fra-2")).to be true
      expect(described_class.linode_gpu_location?("linode-us-sea")).to be true
      expect(described_class.linode_gpu_location?("linode-us-east")).to be false
      expect(described_class.linode_gpu_location?("linode-us-lax")).to be false
    end
  end

  describe ".vm_size_options" do
    let(:linode_location) { instance_double(Location, provider: "linode") }
    let(:azure_location) { instance_double(Location, provider: "azure") }

    it "only exposes VM sizes backed by a Linode plan in Linode locations" do
      names = described_class.vm_size_options(location: linode_location).map(&:display_name)

      expect(names).to include("nanode-1", "nanode-2", "nanode-4", "nanode-8", "standard-2", "standard-4", "standard-8", "standard-16")
      expect(names).not_to include("standard-30", "standard-60")
    end

    it "only exposes VM sizes backed by available Azure plans in Azure locations" do
      names = described_class.vm_size_options(location: azure_location).map(&:display_name)

      expect(names).to eq(["nanode-4", "nanode-8", "standard-2", "standard-4", "standard-8", "standard-16", "burstable-2"])
    end

    it "only exposes the supported Linode GPU VM size for GPU creation" do
      expect(described_class.vm_size_options(location: linode_location, gpu: true).map(&:display_name)).to eq(["standard-4"])
    end
  end

  describe ".kubernetes_worker_size_options" do
    let(:linode_location) { instance_double(Location, provider: "linode") }
    let(:azure_location) { instance_double(Location, provider: "azure") }

    it "only exposes Linode dedicated CPU sizes supported for Kubernetes workers" do
      names = described_class.kubernetes_worker_size_options(location: linode_location).map(&:display_name)

      expect(names).to eq(["standard-2", "standard-4", "standard-8", "standard-16"])
    end

    it "only exposes Azure dedicated CPU sizes supported for Kubernetes workers" do
      names = described_class.kubernetes_worker_size_options(location: azure_location).map(&:display_name)

      expect(names).to eq(["standard-2", "standard-4", "standard-8", "standard-16"])
    end
  end

  describe ".safe_azure_postgres_size_name" do
    it "maps unsupported tiny hobby sizes to the smallest supported Azure Postgres size" do
      expect(described_class.safe_azure_postgres_size_name("hobby-1")).to eq("hobby-2")
      expect(described_class.safe_azure_postgres_size_name("burstable-1")).to eq("hobby-2")
    end
  end

  describe "GCP Postgres options" do
    it "defines all GCP family options" do
      expect(Option::GCP_FAMILY_OPTIONS).to eq(["c4a-standard", "c4a-highmem"])
    end

    it "includes GCP families in POSTGRES_FAMILY_OPTIONS" do
      Option::GCP_FAMILY_OPTIONS.each do |family|
        expect(Option::POSTGRES_FAMILY_OPTIONS).to have_key(family)
      end
    end

    it "defines GCP storage options for all families" do
      Option::GCP_FAMILY_OPTIONS.each do |family|
        expect(Option::GCP_STORAGE_SIZE_OPTIONS).to have_key(family)
      end
    end

    it "has a single fixed storage value per GCP family and vcpu" do
      Option::GCP_STORAGE_SIZE_OPTIONS.each do |family, vcpu_map|
        vcpu_map.each do |vcpu, storage_options|
          expect(storage_options.length).to eq(1), "Expected 1 storage option for #{family} #{vcpu} vCPUs, got #{storage_options.length}"
        end
      end
    end

    it "has matching size options for each GCP family and vcpu" do
      Option::GCP_STORAGE_SIZE_OPTIONS.each do |family, vcpu_map|
        vcpu_map.each_key do |vcpu|
          size_name = "#{family}-#{vcpu}"
          expect(Option::POSTGRES_SIZE_OPTIONS).to have_key(size_name), "Missing POSTGRES_SIZE_OPTIONS entry for #{size_name}"
          expect(Option::POSTGRES_SIZE_OPTIONS[size_name].family).to eq(family)
          expect(Option::POSTGRES_SIZE_OPTIONS[size_name].vcpu_count).to eq(vcpu)
        end
      end
    end

    it "uses correct memory coefficients for GCP families" do
      # standard: 4 GiB/vCPU
      expect(Option::POSTGRES_SIZE_OPTIONS["c4a-standard-8"].memory_gib).to eq(32)
      # highmem: 8 GiB/vCPU
      expect(Option::POSTGRES_SIZE_OPTIONS["c4a-highmem-8"].memory_gib).to eq(64)
    end
  end

  describe "POSTGRES_FAMILY_FALLBACK_CHAINS" do
    it "matches the derivation from POSTGRES_SIZE_OPTIONS" do
      derived = (Option::POSTGRES_SIZE_OPTIONS.values.map(&:family).uniq & Option::AWS_FAMILY_OPTIONS)
        .group_by { it.sub(/\d+/, "") }
        .values
        .map { |chain| chain.sort_by { it[/\d+/].to_i } }
        .reject { |chain| chain.size < 2 }
      expect(Option::POSTGRES_FAMILY_FALLBACK_CHAINS).to eq(derived)
    end
  end

  describe ".postgres_fallback_candidates" do
    it "returns the older family for the newest in a 2-element chain" do
      expect(described_class.postgres_fallback_candidates("m8id")).to eq(["m6id"])
    end

    it "returns the newer family for the oldest in a 2-element chain" do
      expect(described_class.postgres_fallback_candidates("m6id")).to eq(["m8id"])
    end

    it "returns all older alternatives for the newest in a 3-element chain" do
      expect(described_class.postgres_fallback_candidates("c8gd")).to eq(["c6gd", "c7gd"])
    end

    it "returns all newer alternatives for the oldest in a 3-element chain" do
      expect(described_class.postgres_fallback_candidates("c6gd")).to eq(["c7gd", "c8gd"])
    end

    it "returns older alternatives first then newer for a mid-chain family" do
      expect(described_class.postgres_fallback_candidates("c7gd")).to eq(["c6gd", "c8gd"])
    end

    it "returns empty list for a family not in any chain" do
      expect(described_class.postgres_fallback_candidates("standard")).to eq([])
    end
  end

  describe ".postgres_family_rank" do
    it "returns the chain index for a 2-element chain" do
      expect(described_class.postgres_family_rank("m6id")).to eq(0)
      expect(described_class.postgres_family_rank("m8id")).to eq(1)
    end

    it "returns the chain index for a 3-element chain" do
      expect(described_class.postgres_family_rank("c6gd")).to eq(0)
      expect(described_class.postgres_family_rank("c7gd")).to eq(1)
      expect(described_class.postgres_family_rank("c8gd")).to eq(2)
    end

    it "returns -1 for a family not in any chain" do
      expect(described_class.postgres_family_rank("standard")).to eq(-1)
    end
  end

  describe "#kubernetes_upgrade_candidate" do
    it "returns upgrade version for upgradeable version" do
      expect(described_class.kubernetes_upgrade_candidate("v1.33")).to eq("v1.34")
      expect(described_class.kubernetes_upgrade_candidate("v1.34")).to eq("v1.35")
      expect(described_class.kubernetes_upgrade_candidate("v1.35")).to eq("v1.36")
    end

    it "returns nil for latest version" do
      expect(described_class.kubernetes_upgrade_candidate("v1.31")).to be_nil
    end
  end
end
