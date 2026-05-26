# frozen_string_literal: true

require_relative "../model"

class LinodeInstance < Sequel::Model
  many_to_one :vm, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_VM
end

