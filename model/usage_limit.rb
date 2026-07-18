# frozen_string_literal: true

require_relative "../model"

class UsageLimit < Sequel::Model
  THRESHOLDS = [80, 90, 100].freeze

  many_to_one :project, read_only: true
  many_to_one :user, class: :Account, read_only: true
  one_to_many :billing_records, class: :UsageLimitBillingRecord, read_only: true
  one_to_many :notifications, class: :UsageLimitNotification, read_only: true

  plugin ResourceMethods, etc_type: true

  def suspended?
    !suspended_at.nil?
  end

  def usage_percentage(current_cost)
    return 0.0 if limit.to_i <= 0

    (current_cost.to_f / limit * 100).round(2)
  end

  def reconcile!(current_cost, now: Time.now)
    current_period_start = Date.new(now.year, now.month, 1)
    reset_period_if_needed!(current_period_start)
    resume_if_adjusted!(current_cost, current_period_start)
    queue_reached_thresholds!(current_cost)
    UsageLimitEnforcer.suspend!(self, only_if_suspended: true)
    deliver_pending_threshold_notifications!
    self
  end

  def adjust!(new_limit, user_id:, current_cost:, now: Time.now)
    DB.transaction do
      lock!
      update(
        limit: new_limit,
        user_id:,
        revision: revision + 1,
        last_notification_threshold: 0,
        period_start: Date.new(now.year, now.month, 1),
        updated_at: now,
      )
      notifications_dataset.where(delivered_at: nil).destroy
      yield self if block_given?
    end
    notify_safely(:updated, current_cost:)
    reconcile!(current_cost, now:)
  end

  def remove!(current_cost:)
    DB.transaction do
      lock!
      yield self if block_given?
      destroy
    end
    notify_safely(:removed, current_cost:)
  end

  def notify_safely(event, current_cost:)
    UsageLimitEmail.deliver(self, event, current_cost:)
  rescue => ex
    Clog.emit("Failed to send usage-limit notification", Util.exception_to_hash(ex).merge(usage_limit_id: id, project_id:, event:))
    false
  end

  def before_destroy
    UsageLimitEnforcer.resume!(self) if suspended?
    super
  end

  private

  def reset_period_if_needed!(current_period_start)
    return if period_start == current_period_start || suspended?

    DB.transaction do
      lock!
      next if period_start == current_period_start || suspended?

      notifications_dataset.where(delivered_at: nil).destroy
      update(period_start: current_period_start, last_notification_threshold: 0)
    end
  end

  def resume_if_adjusted!(current_cost, current_period_start)
    return unless suspended?
    return unless revision > suspended_revision
    return unless current_cost.to_f < limit

    resumed = DB.transaction do
      lock!
      next false unless suspended? && revision > suspended_revision && current_cost.to_f < limit

      UsageLimitEnforcer.resume!(self)
      update(
        suspended_at: nil,
        suspended_revision: nil,
        period_start: current_period_start,
        last_notification_threshold: 0,
      )
      true
    end
    notify_safely(:resumed, current_cost:) if resumed
  end

  def queue_reached_thresholds!(current_cost)
    DB.transaction do
      lock!
      THRESHOLDS.each do |threshold|
        next if current_cost.to_f < limit * threshold / 100.0

        UsageLimitNotification.dataset.insert_conflict.insert(
          id: UsageLimitNotification.generate_uuid,
          usage_limit_id: id,
          period_start:,
          revision:,
          threshold:,
          current_cost:,
        )
      end
      UsageLimitEnforcer.suspend!(self) if current_cost.to_f >= limit && !suspended?
      update(suspended_revision: revision) if suspended? && revision > suspended_revision
    end
  end

  def deliver_pending_threshold_notifications!
    notifications_dataset.where(delivered_at: nil).order(:period_start, :revision, :threshold).all.each do |notification|
      notification.deliver!
    rescue => ex
      Clog.emit("Failed to send usage-limit threshold notification", Util.exception_to_hash(ex).merge(usage_limit_id: id, project_id:, notification_id: notification.id, threshold: notification.threshold))
    end
  end
end

# Table: usage_limit
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  project_id                  | uuid                     | NOT NULL
#  user_id                     | uuid                     | NOT NULL
#  limit                       | integer                  | NOT NULL
#  period_start                | date                     | NOT NULL
#  last_notification_threshold | integer                  | NOT NULL DEFAULT 0
#  revision                    | integer                  | NOT NULL DEFAULT 1
#  suspended_at                | timestamp with time zone |
#  suspended_revision          | integer                  |
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at                  | timestamp with time zone | NOT NULL DEFAULT now()