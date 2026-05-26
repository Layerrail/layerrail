# frozen_string_literal: true

require_relative "../model"

class PrivateSubnetLinodeResource < Sequel::Model
  many_to_one :private_subnet, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_PRIVATE_SUBNET
end

