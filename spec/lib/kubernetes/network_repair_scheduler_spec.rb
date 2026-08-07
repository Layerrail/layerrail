# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Kubernetes::NetworkRepairScheduler do
  subject(:scheduler) { described_class.new }

  it "schedules every active cluster and refreshes every node rhizome" do
    first = instance_double(KubernetesNode)
    second = instance_double(KubernetesNode)
    location = instance_double(Location, name: "linode-us-lax")
    cluster = instance_double(
      KubernetesCluster,
      ubid: "kc123",
      id: "cluster-id",
      location:,
      all_functional_nodes: [first, second],
    )
    dataset = instance_double(Sequel::Dataset)
    allow(KubernetesCluster).to receive(:association_join).with(:strand).and_return(dataset)
    allow(dataset).to receive_messages(where: dataset, exclude: dataset, all: [cluster])
    expect(first).to receive(:install_rhizome)
    expect(second).to receive(:install_rhizome)
    expect(SemSnap).to receive(:use).with("cluster-id").and_yield(instance_double(SemSnap, set?: false, incr: nil))

    expect(scheduler.run).to eq(
      scheduled: 1,
      clusters: [{cluster: "kc123", location: "linode-us-lax", nodes: 2}],
    )
  end
end
