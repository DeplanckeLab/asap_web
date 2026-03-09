class ProjectViewLog < ApplicationRecord
  belongs_to :project

  validates :project_id, presence: true
  validates :viewer_token, presence: true, length: { maximum: 128 }
  validates :viewed_on, presence: true
end
