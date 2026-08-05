# frozen_string_literal: true

class StandaloneComplianceCheck < ApplicationRecord
  STATUSES = %w[completed failed].freeze

  belongs_to :user, optional: true
  belongs_to :fu, optional: true, class_name: 'Fu'

  validates :status, inclusion: { in: STATUSES }
  validates :checked_at, presence: true
  validates :result_json, presence: true

  scope :recent, -> { order(checked_at: :desc) }
  scope :passed, -> { where(passed: true) }
  scope :failed_outcome, -> { where(passed: false) }
end
