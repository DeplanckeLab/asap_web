class Checkpoint < ApplicationRecord
  belongs_to :project
  belongs_to :user, optional: true

  validates :project_id, presence: true
  validates :title, presence: true

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
end
