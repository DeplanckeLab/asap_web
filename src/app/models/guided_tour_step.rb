class GuidedTourStep < ApplicationRecord
  # Declarative actions run by the tour player. Each entry: { "action" => "...", ... }.
  # scroll_to: { "action" => "scroll_to", "selector" => "#id" }
  # click: { "action" => "click", "selector" => "#id" }
  # wait_for_selector: { "action" => "wait_for_selector", "selector" => "#id", "timeout_ms" => 5000 }
  ACTION_REQUIRED_KEYS = {
    'scroll_to' => ['selector'],
    'click' => ['selector'],
    'wait_for_selector' => ['selector']
  }.freeze

  belongs_to :guided_tour, inverse_of: :guided_tour_steps

  validates :page_url, presence: true
  validates :title, presence: true
  validates :focus_element, presence: true
  validates :rank, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validate :step_actions_shape

  before_validation :assign_rank, on: :create
  before_validation :apply_step_actions_json

  scope :ordered, -> { order(:rank, :id) }

  def step_actions_json
    if instance_variable_defined?(:@step_actions_json)
      return @step_actions_json
    end

    actions = step_actions
    return '[]' if actions.blank?

    JSON.pretty_generate(actions.as_json)
  end

  def step_actions_json=(value)
    @step_actions_json = value
  end

  private

  def apply_step_actions_json
    return unless instance_variable_defined?(:@step_actions_json)

    raw = @step_actions_json
    self.step_actions =
      if raw.blank?
        []
      else
        JSON.parse(raw)
      end
  rescue JSON::ParserError
    errors.add(:step_actions, 'must be valid JSON')
  end

  def step_actions_shape
    list = step_actions

    unless list.is_a?(Array)
      errors.add(:step_actions, 'must be a JSON array')
      return
    end

    return if list.empty?

    list.each_with_index do |item, index|
      unless item.is_a?(Hash)
        errors.add(:step_actions, "entry #{index + 1} must be a JSON object")
        next
      end

      action = item['action']
      unless action.is_a?(String) && action.present?
        errors.add(:step_actions, "entry #{index + 1} needs a non-empty action string")
        next
      end

      required = ACTION_REQUIRED_KEYS[action]
      unless required
        errors.add(:step_actions, "entry #{index + 1} uses unknown action #{action.inspect}")
        next
      end

      required.each do |key|
        val = item[key]
        errors.add(:step_actions, "entry #{index + 1} (#{action}) requires #{key}") if val.blank?
      end

      next unless action == 'wait_for_selector' && item.key?('timeout_ms')

      timeout = item['timeout_ms']
      unless timeout.is_a?(Integer) && timeout.positive?
        errors.add(:step_actions, "entry #{index + 1} (wait_for_selector) timeout_ms must be a positive integer")
      end
    end
  end

  def assign_rank
    return if rank.present? || guided_tour.nil?

    self.rank = (guided_tour.guided_tour_steps.maximum(:rank) || 0) + 1
  end
end
