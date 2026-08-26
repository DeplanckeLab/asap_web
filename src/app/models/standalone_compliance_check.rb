# frozen_string_literal: true

class StandaloneComplianceCheck < ApplicationRecord
  STATUSES = %w[completed failed].freeze
  ORIGIN_FILTERS = %w[user admin all].freeze
  DEFAULT_ORIGIN_FILTER = 'user'

  belongs_to :user, optional: true
  belongs_to :fu, optional: true, class_name: 'Fu'

  validates :status, inclusion: { in: STATUSES }
  validates :checked_at, presence: true
  validates :result_json, presence: true

  scope :recent, -> { order(checked_at: :desc) }
  scope :passed, -> { where(passed: true) }
  scope :failed_outcome, -> { where(passed: false) }
  scope :admin_runs, -> { where(admin_run: true) }
  scope :user_runs, -> { where(admin_run: false) }

  def self.origin_filter(value)
    key = value.to_s.strip.presence || DEFAULT_ORIGIN_FILTER
    ORIGIN_FILTERS.include?(key) ? key : DEFAULT_ORIGIN_FILTER
  end

  def self.for_origin_filter(value)
    case origin_filter(value)
    when 'admin' then admin_runs
    when 'all' then all
    else user_runs
    end
  end

  def guest?
    user_id.blank?
  end
end
