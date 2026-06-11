# frozen_string_literal: true

class Serializers::DomainBundle < Serializers::Base
  def self.serialize_internal(bundle, _options = {})
    {
      id: bundle.ubid,
      name: bundle.name,
      slug: bundle.slug,
      type: bundle.bundle_type,
      state: bundle.status,
      description: bundle.description,
      domain_registration_id: bundle.domain_registration&.ubid,
      deploy_app_id: bundle.deploy_app&.ubid,
      settings: bundle.settings.to_h,
      created_at: bundle.created_at,
      updated_at: bundle.updated_at
    }
  end
end
