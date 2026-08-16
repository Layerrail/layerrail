# frozen_string_literal: true

Sequel.migration do
  up do
    # Make the public AWS regions selectable as secondary compute locations
    # alongside the primary Azure locations.
    run <<~SQL
      UPDATE location
      SET visible = true
      WHERE provider = 'aws' AND project_id IS NULL AND name IN ('us-east-1', 'us-west-2');
    SQL
  end

  down do
    run <<~SQL
      UPDATE location
      SET visible = false
      WHERE provider = 'aws' AND project_id IS NULL AND name IN ('us-east-1', 'us-west-2');
    SQL
  end
end
