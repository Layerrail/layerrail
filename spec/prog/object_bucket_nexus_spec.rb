# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::ObjectBucketNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "bucket-limit-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:cluster) do
    MinioCluster.create(
      name: "bucket-limit-cluster",
      admin_user: "admin-user",
      admin_password: "admin-password",
      project_id: project.id,
      location_id: location.id,
    )
  end
  let(:bucket) do
    ObjectBucket.create(
      project_id: project.id,
      location_id: location.id,
      minio_cluster_id: cluster.id,
      name: "limited-bucket",
      bucket_name: "limited-bucket-storage",
      access_key: "limited-access-key",
      secret_key: "limited-secret-key",
      state: "ready",
      endpoint: "https://storage.example.com",
    )
  end
  let(:strand) { Strand.create_with_id(bucket, prog: "ObjectBucketNexus", label: "usage_limit_suspend", stack: [{"subject_id" => bucket.id}]) }
  let(:admin_client) { instance_double(Minio::Client) }

  before do
    allow(nx).to receive(:admin_client).and_return(admin_client)
  end

  it "holds in-flight provisioning while usage-limited" do
    bucket.update(state: "creating")
    strand.update(label: "start")
    bucket.incr_usage_limit_suspended
    fresh_nx = described_class.new(strand.reload)

    expect { fresh_nx.before_run }.to nap(5 * 60)
  end

  it "disables credentials while preserving the bucket" do
    bucket.incr_usage_limit_suspended
    expect(admin_client).to receive(:admin_set_user_status).with(bucket.access_key, "disabled")

    expect { nx.usage_limit_suspend }.to hop("usage_limit_suspended")

    expect(bucket.reload.state).to eq("suspended")
    expect(bucket.exists?).to be(true)
  end

  it "re-enables credentials after the limit is adjusted" do
    bucket.update(state: "suspended")
    nx.incr_usage_limit_resume
    allow(bucket).to receive(:ensure_billing_record!)
    expect(admin_client).to receive(:admin_set_user_status).with(bucket.access_key, "enabled")

    expect { nx.usage_limit_resume }.to hop("wait")

    expect(bucket.reload.state).to eq("ready")
    expect(Semaphore.where(strand_id: bucket.id, name: "usage_limit_resume")).to be_empty
  end
end