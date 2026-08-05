# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Semaphore do
  let(:st) { Strand.create(prog: "Test", label: "start") }

  it ".incr returns nil and does not add Semaphore if there is no related strand" do
    expect(described_class.all).to be_empty
    expect(described_class.incr(Vm.generate_uuid, "foo")).to be_nil
    expect(described_class.all).to be_empty
  end

  it ".incr raises if invalid name is given" do
    expect { described_class.incr(st.id, nil) }.to raise_error(RuntimeError)
  end

  it ".incr coalesces repeated destroy signals" do
    st.update(schedule: Time.now + 60)

    3.times { described_class.incr(st.id, :destroy) }

    expect(described_class.where(strand_id: st.id, name: "destroy").count).to eq(1)
    expect(st.reload.schedule).to be < Time.now + 5
  end

  it ".incr only wakes a strand if destruction is already underway" do
    described_class.incr(st.id, :destroying)
    st.update(schedule: Time.now + 60)

    3.times { described_class.incr(st.id, :destroy) }

    expect(described_class.where(strand_id: st.id, name: "destroy")).to be_empty
    expect(st.reload.schedule).to be < Time.now + 5
  end

  it ".set_at returns the Time the given semaphore id was set at" do
    time = described_class.set_at(described_class.generate_uuid)
    expect(time).to be_within(1).of(Time.now)
    expect(time.inspect).to match(/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(\.\d{1,3})? UTC\z/)
  end

  it "#set_at returns the Time the semaphore was set at" do
    sem = described_class.create(name: "foo", strand_id: st.id)
    expect(sem.set_at).to be_within(1).of(Time.now)
  end

  it "#inspect_values_hash includes set_at" do
    sem = described_class.create(name: "foo", strand_id: st.id)
    expect(Time.parse(sem.inspect_values_hash[:set_at] + " UTC")).to be_within(2).of(Time.now)
  end
end
