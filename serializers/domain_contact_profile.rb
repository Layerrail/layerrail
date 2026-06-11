# frozen_string_literal: true

class Serializers::DomainContactProfile < Serializers::Base
  def self.serialize_internal(profile, options = {})
    base = {
      id: profile.ubid,
      name: profile.name,
      full_name: profile.full_name,
      organization: profile.organization,
      email: profile.email,
      country_code: profile.country_code,
      created_at: profile.created_at,
      updated_at: profile.updated_at
    }

    if options[:detailed]
      base.merge!(
        phone: profile.phone,
        address1: profile.address1,
        address2: profile.address2,
        city: profile.city,
        state: profile.state,
        postal_code: profile.postal_code
      )
    end

    base
  end
end
