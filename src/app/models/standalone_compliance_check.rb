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
  # Checks whose source_url matches an external catalog candidate for the portal.
  scope :for_portal_source, lambda { |source|
    key = portal_source_filter(source)
    next all if key.blank?

    where(
      source_url: ExternalCatalogCandidate.where(source: key).where.not(url: [nil, '']).select(:url)
    )
  }

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

  # Blank = all portals. Unknown values are ignored (treated as all).
  def self.portal_source_filter(value)
    key = value.to_s.strip.presence
    return nil if key.blank?

    ExternalCatalogCandidate::SOURCES.include?(key) ? key : nil
  end

  # Latest completed admin-run outcome per source_url for catalog list views.
  # Returns { source_url => { id:, passed: } }; missing keys mean not yet validated.
  def self.latest_passed_by_source_url(urls)
    list = Array(urls).map { |u| u.to_s.strip.presence }.compact.uniq
    return {} if list.empty?

    result = {}
    admin_runs.where(source_url: list, status: "completed").order(checked_at: :desc).each do |row|
      next if result.key?(row.source_url)

      result[row.source_url] = { id: row.id, passed: row.passed }
    end
    result
  end

  # Latest check matching exact source_url and/or filename (both ANDed when given).
  def self.latest_matching(source_url: nil, filename: nil)
    url = source_url.to_s.strip.presence
    name = filename.to_s.strip.presence
    return none if url.blank? && name.blank?

    scope = recent
    scope = scope.where(source_url: url) if url
    scope = scope.where(filename: name) if name
    scope
  end

  def guest?
    user_id.blank?
  end
end
