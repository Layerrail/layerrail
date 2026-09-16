# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Database connection validation" do
  let(:database) do
    Sequel.connect(DB.opts.merge(max_connections: 1, keep_reference: false)).tap do |connection_pool|
      connection_pool.extension :connection_validator
      # Exercise stale socket recovery without waiting for the production idle interval.
      connection_pool.pool.connection_validation_timeout = -1
    end
  end

  after do
    database.disconnect
  end

  it "checks primary database connections after thirty seconds idle" do
    expect(DB.pool.connection_validation_timeout).to eq(30)
  end

  it "replaces a dead pooled socket before running application SQL once" do
    dead_connection = database.synchronize { it }
    dead_connection.finish
    executions = 0

    value = database.synchronize do |connection|
      executions += 1
      expect(connection).not_to equal(dead_connection)
      database.get(Sequel.lit("1"))
    end

    expect(value).to eq(1)
    expect(executions).to eq(1)
  end

  it "does not replay application work when a connection drops after checkout" do
    executions = 0

    expect {
      database.synchronize do |connection|
        executions += 1
        connection.finish
        database.get(Sequel.lit("1"))
      end
    }.to raise_error(Sequel::DatabaseDisconnectError)

    expect(executions).to eq(1)
    expect(database.get(Sequel.lit("1"))).to eq(1)
  end
end
