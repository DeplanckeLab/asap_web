class Checkpoint < ApplicationRecord
  KIND_VISUALIZATION = "visualization".freeze
  KIND_HEATMAP = "heatmap".freeze
  KINDS = [KIND_VISUALIZATION, KIND_HEATMAP].freeze
  CURRENT_VISUALIZATION_TITLE = "__current_visualization_view__".freeze
  CURRENT_HEATMAP_TITLE = "__current_heatmap_view__".freeze
  CURRENT_TITLES = [CURRENT_VISUALIZATION_TITLE, CURRENT_HEATMAP_TITLE].freeze
  CURRENT_DISPLAY_TITLE = "Current auto checkpoint".freeze

  belongs_to :project
  belongs_to :user, optional: true
  belongs_to :run, optional: true

  validates :project_id, presence: true
  validates :title, presence: true
  validates :kind, inclusion: { in: KINDS }
  validate :heatmap_requires_run
  validate :visualization_forbids_run
  validate :run_belongs_to_project

  scope :visualization, -> { where(kind: KIND_VISUALIZATION) }
  scope :heatmap, -> { where(kind: KIND_HEATMAP) }
  scope :for_run, ->(run_id) { where(run_id: run_id) }

  def state
    JSON.parse(state_json.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def state=(value)
    self.state_json = (value || {}).to_json
  end

  def comments
    JSON.parse(comments_json.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def comments=(value)
    self.comments_json = (value || []).to_json
  end

  def heatmap?
    kind == KIND_HEATMAP
  end

  def visualization?
    kind == KIND_VISUALIZATION
  end

  def current_auto?
    CURRENT_TITLES.include?(title)
  end

  def comments_empty?
    comments.blank?
  end

  def display_title
    current_auto? ? CURRENT_DISPLAY_TITLE : title
  end

  private

  def heatmap_requires_run
    return unless heatmap?
    return if run_id.present?

    errors.add(:run_id, "is required for heatmap checkpoints")
  end

  def visualization_forbids_run
    return unless visualization?
    return if run_id.blank?

    errors.add(:run_id, "must be blank for visualization checkpoints")
  end

  def run_belongs_to_project
    return if run_id.blank?
    return unless run
    return if run.project_id == project_id

    errors.add(:run_id, "does not belong to this project")
  end
end
