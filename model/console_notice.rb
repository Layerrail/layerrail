# frozen_string_literal: true

require_relative "../model"
require "uri"

class ConsoleNotice < Sequel::Model(:console_notice)
  SEVERITIES = %w[info maintenance warning incident].freeze

  def self.current
    first || create(enabled: false, severity: "maintenance", title: "Upcoming maintenance", body: "")
  end

  def self.active
    now = Time.now.utc
    where(enabled: true)
      .where { (starts_at =~ nil) | (starts_at <= now) }
      .where { (ends_at =~ nil) | (ends_at > now) }
      .reverse(:updated_at)
      .first
  end

  def self.update_current_from_admin(params)
    notice = current
    notice.update(
      enabled: params.fetch(:enabled),
      severity: params.fetch(:severity),
      title: params.fetch(:title).to_s.strip,
      body: params.fetch(:body).to_s.strip,
      link_label: empty_to_nil(params[:link_label]),
      link_url: empty_to_nil(params[:link_url]),
      starts_at: params[:starts_at],
      ends_at: params[:ends_at],
      updated_at: Time.now.utc
    )
  end

  def self.empty_to_nil(value)
    value = value.to_s.strip
    value.empty? ? nil : value
  end

  def validate
    super
    errors.add(:severity, "is invalid") unless SEVERITIES.include?(severity)
    errors.add(:title, "cannot be empty") if title.to_s.strip.empty?
    errors.add(:body, "cannot be empty") if body.to_s.strip.empty? && enabled
    validate_link
  end

  def dismiss_key
    "#{id}-#{updated_at.to_i}"
  end

  def link?
    !link_label.to_s.empty? && !link_url.to_s.empty?
  end

  def link_url_for(project: nil)
    url = link_url.to_s
    return nil if url.empty?

    if url.include?("{project_id}") || url.include?("{project_path}")
      return nil unless project

      url = url.gsub("{project_id}", project.ubid)
      url = url.gsub("{project_path}", project.path)
    end

    url
  end

  def style_key
    SEVERITIES.include?(severity) ? severity : "maintenance"
  end

  private

  def validate_link
    return if link_url.to_s.empty?

    url_for_validation = link_url
      .gsub("{project_id}", "pjexample")
      .gsub("{project_path}", "/project/pjexample")

    uri = URI.parse(url_for_validation)
    valid = if uri.relative?
      url_for_validation.start_with?("/")
    else
      %w[https http mailto].include?(uri.scheme)
    end
    errors.add(:link_url, "must be an https, http, mailto, or relative URL") unless valid
  rescue URI::InvalidURIError
    errors.add(:link_url, "is invalid")
  end
end
