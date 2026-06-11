# frozen_string_literal: true

class Location < Sequel::Model
  module Azure
    private

    def azure_azs
      []
    end
  end
end
