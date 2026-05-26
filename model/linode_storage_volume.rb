# frozen_string_literal: true

require_relative "../model"

class LinodeStorageVolume < Sequel::Model
  many_to_one :vm_storage_volume, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, referencing: UBID::TYPE_VM_STORAGE_VOLUME
end
