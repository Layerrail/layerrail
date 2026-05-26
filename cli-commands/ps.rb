# frozen_string_literal: true

UbiCli.base("ps") do
  banner "lr ps command [...]"
  post_banner "lr ps (location/ps-name | ps-id) post-command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/ps")
