class ProjectStep < ApplicationRecord
  belongs_to :project
  belongs_to :step
  belongs_to :status, optional: true
  belongs_to :job, optional: true

  validates :project_id, presence: true
  validates :step_id, presence: true
  validates :project_id, uniqueness: { scope: :step_id }
end




