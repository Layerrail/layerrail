# frozen_string_literal: true

class Location < Sequel::Model
  module Linode
    private

    def linode_azs
      []
    end
  end
end

