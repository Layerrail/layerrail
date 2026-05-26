# frozen_string_literal: true

UbiCli.base("fw") do
  banner "lr fw command [...]"
  post_banner "lr fw (location/fw-name | fw-id) post-command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/fw")
