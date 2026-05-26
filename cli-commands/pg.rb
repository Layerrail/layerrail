# frozen_string_literal: true

UbiCli.base("pg") do
  banner "lr pg command [...]"

  post_options("lr pg (location/pg-name | pg-id) [post-options] post-command [...]", key: :pg_psql) do
    on("-d", "--dbname=name", "override database name")
    on("-U", "--username=name", "override username")
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/pg")
