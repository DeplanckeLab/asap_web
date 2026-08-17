# frozen_string_literal: true

class ModuleScoreRequest < ApplicationRecord
  STATUSES = %w[pending running completed failed canceled].freeze
  TERMINAL_STATUSES = %w[completed failed canceled].freeze

  belongs_to :project
  belongs_to :user, optional: true

  validates :request_id, presence: true, uniqueness: true
  validates :item_id, presence: true
  validates :loom_file, presence: true
  validates :dataset, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def canceled?
    status == 'canceled'
  end

  def pending_or_running?
    status == 'pending' || status == 'running'
  end

  def result_dir
    project.data_dir + 'module_score_requests'
  end

  def write_scores!(scores)
    FileUtils.mkdir_p(result_dir)
    path = result_dir.join("#{request_id}.json").to_s
    File.write(path, JSON.generate({ 'scores' => scores }))
    path
  end

  def read_scores
    raise ArgumentError, "ModuleScore result file is missing for request #{request_id}" if result_path.blank?
    raise ArgumentError, "ModuleScore result file is missing for request #{request_id}" unless File.exist?(result_path)

    parsed = JSON.parse(File.read(result_path))
    scores = parsed['scores']
    raise ArgumentError, "ModuleScore result is invalid for request #{request_id}" unless scores.is_a?(Array)

    scores
  end
end
