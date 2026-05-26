# frozen_string_literal: true

UbiCli.on("version") do
  desc "Display CLI program version"

  banner "lr version"

  run do
    response(client_version)
  end
end
