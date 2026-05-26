# frozen_string_literal: true

UbiCli.on("pg").run_on("upgrade") do
  desc "Schedule a major version upgrade of the PostgreSQL database"

  banner "lr pg (location/pg-name | pg-id) upgrade"

  run do
    id = sdk_object.upgrade.id
    response("Scheduled major version upgrade of PostgreSQL database with id #{id} to version #{sdk_object.target_version}.")
  end
end
