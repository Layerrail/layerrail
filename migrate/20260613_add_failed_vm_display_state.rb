# frozen_string_literal: true

Sequel.migration do
  change do
    run "ALTER TYPE vm_display_state ADD VALUE IF NOT EXISTS 'failed'"
  end
end
