# frozen_string_literal: true

UbiCli.base("kc") do
  banner "lr kc command [...]"
  post_banner "lr kc (location/kc-name | kc-id) post-command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/kc")
