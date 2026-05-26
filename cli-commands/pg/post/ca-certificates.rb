# frozen_string_literal: true

UbiCli.on("pg").run_on("ca-certificates") do
  desc "Print CA certificates for a PostgreSQL database"

  banner "lr pg (location/pg-name | pg-id) ca-certificates"

  run do
    response(sdk_object.ca_certificates)
  end
end
